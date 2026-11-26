package compiler.semantic;

import compiler.core.DiagnosticCode;
import compiler.core.QualifiedName;
import compiler.syntax.Ast;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.syntax.AstFunctions;
import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.compilation.CompilationContext;
import compiler.modules.ModuleState;
import compiler.core.CancellationToken;
import compiler.semantic.Invalidation.InvalidatedArtifact;
import compiler.semantic.Invalidation.InvalidationKind;
import compiler.semantic.Invalidation.InvalidationReason;
import compiler.semantic.DeclarationFacts.FactAspect;
import compiler.semantic.DeclarationFacts.UnitReads;

typedef SemanticAssemblyResult = {
	final canonicalProgram:AstProgram;
	final functions:Array<AstFunction>;
	final owners:Map<String, String>;
	final generatedByModule:Map<String, Map<String, Bool>>;
	final invalidated:Map<String, Bool>;
	final selected:Map<String, Bool>;
	final invalidations:Array<InvalidatedArtifact>;
	final entryPoint:String;

	/** Where a missing entry point is reported (SessionState.executableEntrySpan). */
	final entrySpan:Null<compiler.core.Source.SourceSpan>;

	/** The canonical names of the declarations whose type is inferred from their own body or initializer. */
	final inferredDeclarations:Map<String, Bool>;

	/** The purity and no-return answers the invalidation was decided against, for the typer to use as they are. */
	final facts:ProgramFacts;

	/** Where each module's `using` and each type's `@:using` find static extensions. */
	final staticExtensions:StaticExtensionTable;

	final aliasSetupMs:Float;
	final canonicalizationMs:Float;
	final contributionReuseMs:Float;
	final contributionRebuildMs:Float;
	final invalidationMs:Float;
	final allocatedBytes:Float;
}

/** Canonicalizes reachable declarations and selects the units to type again: those that read a fact that changed. */
class SemanticAssembly {
	public static function run(context:CompilationContext, entryModule:String, token:Null<CancellationToken>,
			rollbackModules:Map<String, ModuleState>,
			names:Array<String>, structuralChanged:Map<String, Bool>,
			refreshUnchangedModules:Bool = true):SemanticAssemblyResult {
		var startedAt = Sys.time() * 1000.0;
		var facts = context.state.declarationFacts;
		facts.beginBuild();
		#if haxeon
		var allocatedAtStart = hl.Gc.totalAllocated();
		#elseif hl
		var allocatedAtStart = hl.Gc.stats().totalAllocated;
		#end
		var contributionReuseMs = 0.0, contributionRebuildMs = 0.0;
		var modules = context.state.modules;
		var functions:Array<AstFunction> = [],
			programFunctions:Array<AstFunction> = [],
			typeAliases:Array<compiler.syntax.Ast.AstTypeAlias> = [],
			enums:Array<compiler.syntax.Ast.AstEnum> = [],
			abstracts:Array<compiler.syntax.Ast.AstAbstract> = [],
			interfaces:Array<compiler.syntax.Ast.AstInterface> = [],
			classes:Array<compiler.syntax.Ast.AstClass> = [],
			owners:Map<String, String> = [],
			generatedByModule:Map<String, Map<String, Bool>> = [];
		var sourceTypeAliases:Map<String, String> = [],
			aliasesByModule:Map<String, Array<{sourceName:String, declarationName:String}>> = [],
			visibleAliasesByPackage:Map<String, Map<String, String>> = [],
			enumCasesByType:Map<String, Array<String>> = [];
		// The declarations whose type is inferred from their own body or initializer.
		var inferredDeclarations:Map<String, Bool> = [];
		for (moduleName in names) {
			if (!modules.exists(moduleName))
				continue;
			var moduleState = modules.get(moduleName),
				program = moduleState.parsedAst();
			var moduleAliases:Array<{sourceName:String, declarationName:String}> = [];
			aliasesByModule.set(moduleName, moduleAliases);
			for (declaration in program.aliases)
				addSourceAlias(sourceTypeAliases, moduleAliases, moduleName, declaration.name, program.packageName);
			for (declaration in program.enums) {
				var canonicalName = ModuleCanonicalizer.qualifiedTypeName(program.packageName, declaration.name);
				addSourceAlias(sourceTypeAliases, moduleAliases, moduleName, declaration.name, program.packageName);
				enumCasesByType.set(canonicalName, [for (enumCase in declaration.cases) enumCase.name]);
			}
			for (declaration in program.abstracts) {
				addSourceAlias(sourceTypeAliases, moduleAliases, moduleName, declaration.name, program.packageName);
				if (declaration.values != null)
					enumCasesByType.set(ModuleCanonicalizer.qualifiedTypeName(program.packageName, declaration.name),
						[for (value in declaration.values) value.name]);
			}
			for (declaration in program.interfaces)
				addSourceAlias(sourceTypeAliases, moduleAliases, moduleName, declaration.name, program.packageName);
			for (declaration in program.classes)
				addSourceAlias(sourceTypeAliases, moduleAliases, moduleName, declaration.name, program.packageName);
			collectInferredDeclarations(program, moduleName, entryModule, inferredDeclarations);
		}
		// Type names that every module sees: dotted ones ("pkg.Type") and plain ones ("Type"). They are attached to each module's
		// table as shared layers instead of being copied into it.
		var aliasesByPackage = indexAliasesByPackage(sourceTypeAliases);
		var dottedSourceAliases:Map<String, String> = [],
			plainSourceAliases:Map<String, String> = [];
		for (sourceName => declarationName in sourceTypeAliases)
			if (sourceName.indexOf(".") >= 0)
				dottedSourceAliases.set(sourceName, declarationName);
			else
				plainSourceAliases.set(sourceName, declarationName);
		var patternConstants:Map<String, Bool> = [];
		var aliasUniverse = [
			for (sourceName => declarationName in sourceTypeAliases)
				sourceName + "=" + declarationName
		];
		for (typeName => caseNames in enumCasesByType)
			for (caseName in caseNames) {
				aliasUniverse.push(typeName + "#" + caseName);
				patternConstants.set(typeName + "." + caseName, true);
			}
		// Where each module-level variable is stored (ModuleFields): name resolution names it there. A module that adds or removes
		// one changes the key, so the modules that resolve names are resolved again.
		// One that shares its name with a static of the module's own class is that static when named through the imported class.
		// Every module-level variable and function by its path as a module member, which tells the module-namespace uses apart: one
		// added or removed changes no name's meaning in a module that compiles, so it is not part of the key.
		var moduleFieldStorage:Map<String, String> = [],
			moduleTypeStatics:Map<String, Bool> = [],
			moduleMembers:Map<String, Bool> = [];
		for (moduleName in names)
			if (modules.exists(moduleName)) {
				var parsed = modules.get(moduleName).parsedAst();
				for (decl in parsed.classes)
					for (field in decl.fields)
						if (field.isStatic && field.isInline) {
							var path = ModuleCanonicalizer.qualifiedTypeName(parsed.packageName,
								decl.name) + "." + field.name;
							patternConstants.set(path, true);
							aliasUniverse.push("inline " + path);
						}
				for (fn in parsed.functions)
					moduleMembers.set(moduleName + "." + fn.name, true);
				if (parsed.fields != null) {
					var ownClass = null;
					for (decl in parsed.classes)
						if (ModuleCanonicalizer.qualifiedTypeName(parsed.packageName, decl.name) == moduleName)
							ownClass = decl;
					for (field in parsed.fields) {
						var path = moduleName + "." + field.name;
						moduleFieldStorage.set(path, ModuleFields.storageName(moduleName) + "." + field.name);
						if (field.isInline) {
							patternConstants.set(ModuleFields.storageName(moduleName) + "." + field.name, true);
							aliasUniverse.push("inline " + path);
						}
						moduleMembers.set(path, true);
						aliasUniverse.push("field " + path);
						if (ownClass != null && declaresStatic(ownClass, field.name)) {
							moduleTypeStatics.set(path, true);
							aliasUniverse.push("static " + path);
						}
					}
				}
			}
		aliasUniverse.sort(Reflect.compare);
		var aliasKey = aliasUniverse.join(";"), session = context.state;
		if (session.aliasUniverse != aliasKey) {
			session.aliasUniverse = aliasKey;
			session.aliasUniverseRevision = facts.revision;
		}
		var aliasRevision = session.aliasUniverseRevision;
		var discoveryPrefixes:Map<String, Array<String>> = [];
		for (moduleName in names) {
			if (!modules.exists(moduleName))
				continue;
			var program = modules.get(moduleName).parsedAst();
			for (classDecl in program.classes) {
				var prefixes = declaredDiscoveryPrefixes(classDecl);
				if (prefixes != null)
					discoveryPrefixes.set(ModuleCanonicalizer.qualifiedTypeName(program.packageName, classDecl.name),
						prefixes);
			}
		}
		var reuseModuleContributions = !changesDiscoveredMethods(structuralChanged);
		if (reuseModuleContributions) {
			var discovered = true;
			while (discovered) {
				discovered = false;
				for (moduleName in names) {
					var cachedState = modules.get(moduleName);
					if (cachedState == null)
						continue;
					for (classDecl in cachedState.canonicalClasses) {
						var baseName = nominalTypeName(classDecl.base);
						if (baseName != null && discoveryPrefixes.exists(baseName)
							&& !discoveryPrefixes.exists(classDecl.name)) {
							discoveryPrefixes.set(classDecl.name, discoveryPrefixes.get(baseName));
							discovered = true;
						}
					}
				}
			}
		}
		var staticExtensions = StaticExtensionTable.build(modules, names);
		var aliasesPreparedAt = Sys.time() * 1000.0;
		for (name in names) {
			var contributionStartedAt = Sys.time() * 1000.0;
			if (token != null)
				token.check();
			if (!modules.exists(name))
				continue;
			var state = modules.get(name), ast = state.parsedAst();
			if (reuseModuleContributions
				&& state.canonicalRevision == state.revision
				&& state.canonicalEntry == entryModule
				&& state.canonicalAliasRevision == aliasRevision) {
				for (value in state.canonicalAliases)
					typeAliases.push(value);
				for (value in state.canonicalEnums)
					enums.push(value);
				for (value in state.canonicalAbstracts)
					abstracts.push(value);
				for (value in state.canonicalInterfaces)
					interfaces.push(value);
				for (value in state.canonicalClasses) {
					classes.push(value);
					owners.set(value.name + ".new", name);
				}
				for (fn in state.canonicalAllFunctions) {
					functions.push(fn);
					owners.set(fn.name, name);
				}
				for (fn in state.canonicalProgramFunctions)
					programFunctions.push(fn);
				if (state.canonicalGeneratedFunctions.length > 0)
					generatedByModule.set(name,
						[for (functionName in state.canonicalGeneratedFunctions) functionName => true]);
				contributionReuseMs += Sys.time() * 1000.0 - contributionStartedAt;
				continue;
			}
			// The facts of the module's declarations are moved by what changed since they were last made (`DeclarationPrints`).
			var before = state.canonicalRevision > 0 ? canonicalContribution(state) : null,
				scope = scopeKey(ast),
				sameScope = state.canonicalScope == scope && state.canonicalAliasRevision == aliasRevision;
			var importedTypes = context.moduleAnalyzer.importAliases(ast.imports),
				locals = LocalScope.ofNames([]),
				aliases = AliasTable.of(importedTypes);
			aliases.useModuleFieldStorage(moduleFieldStorage, moduleTypeStatics, moduleMembers);
			aliases.usePatternConstants(patternConstants);
			var namespaceUses:Array<AliasTable.ModuleNamespaceUse> = [];
			aliases.recordNamespaceUses(namespaceUses);
			// An explicit import outranks a same-named type elsewhere in the
			// program, such as an unpackaged `Path` shadowing `import nav.Path`.
			// Unpackaged names wait until the current package's own types are in:
			// in `package nav`, a plain `Path` is `nav.Path`, as in Haxe.
			aliases.attach(dottedSourceAliases);
			var constructorTargets:Map<String, String> = [],
				ambiguousConstructors:Map<String, Bool> = [];
			for (imported in ast.imports) {
				var importPath = imported.path;
				var importedTypes:Array<String> = [],
					importConstructors:Map<String, String> = [],
					ambiguousImportConstructors:Map<String, Bool> = [];
				if (ModuleAnalyzer.isWildcardImport(importPath)) {
					// `import pack.Type.*` imports the type's statics: an enum's constructors and an enum abstract's values are among
					// them, as in Haxe. A package's wildcard imports its types without their constructors.
					var wildcardType = sourceTypeAliases.get(ModuleAnalyzer.importModulePath(importPath));
					if (wildcardType != null)
						importedTypes.push(wildcardType);
				} else {
					var importedType = sourceTypeAliases.get(importPath);
					if (importedType != null)
						importedTypes.push(importedType);
					// Importing a module imports every type declared in it, and with
					// each enum its constructors, as in Haxe.
					if (aliasesByModule.exists(importPath)
						&& (imported.alias == null || imported.alias == QualifiedName.last(importPath)))
						for (entry in aliasesByModule.get(importPath))
							if (importedTypes.indexOf(entry.declarationName) < 0)
								importedTypes.push(entry.declarationName);
				}
				for (type in importedTypes)
					if (enumCasesByType.exists(type))
						for (caseName in enumCasesByType.get(type))
							if (!importConstructors.exists(caseName))
								importConstructors.set(caseName, type + "." + caseName);
							// The same enum reached through its module and through
							// its own import is not a clash.
							else if (importConstructors.get(caseName) != type + "." + caseName)
								ambiguousImportConstructors.set(caseName, true);
				// A later explicit import supplies the default constructor, as in Haxe.
				// Collisions within a single module import remain ambiguous.
				for (caseName => target in importConstructors) {
					constructorTargets.set(caseName, target);
					if (ambiguousImportConstructors.exists(caseName))
						ambiguousConstructors.set(caseName, true);
					else
						ambiguousConstructors.remove(caseName);
				}
			}
			for (imported in ast.imports) {
				var importPath = imported.path;
				var importedModule = ModuleAnalyzer.importModulePath(importPath);
				if (aliasesByModule.exists(importedModule)
					&& (imported.alias == null || imported.alias == QualifiedName.last(importPath)))
					for (entry in aliasesByModule.get(importedModule)) {
						var qualifiedSourceName = entry.sourceName;
						if (StringTools.startsWith(qualifiedSourceName, importedModule + ".")) {
							var nestedStart = importedModule.length + 1,
								nestedName = qualifiedSourceName.substring(nestedStart, qualifiedSourceName.length);
							if (nestedName.indexOf(".") < 0 && !aliases.exists(nestedName))
								aliases.set(nestedName, entry.declarationName);
						}
					}
			}
			var visiblePackage = ast.packageName;
			if (visiblePackage != null) {
				var packageTypes = visibleTypeAliases(visiblePackage, aliasesByPackage, visibleAliasesByPackage);
				// A name an import would silently take from this package resolves to a marker the typer reports where it is used.
				for (name => marker in ImportShadowing.ambiguousNames(ast, importedTypes, packageTypes))
					aliases.set(name, marker);
				aliases.attach(packageTypes);
			}
			aliases.attach(plainSourceAliases);
			ModuleCanonicalizer.addDeclaredTypeAliases(aliases, ast, ast.packageName);
			// Enum constructors imported through their enum type are expression aliases, so a type of the same name keeps it in
			// type positions such as `new Tabs()`. In an expression an imported constructor comes before a type of the package or
			// the program, as in Haxe (`Lambda(3)` with `import pack.Shape` is Shape's constructor, not the class `Lambda`); a
			// type the module declares or imports by name keeps the name.
			for (caseName => target in constructorTargets)
				if (!ambiguousConstructors.exists(caseName) && !importedTypes.exists(caseName)
					&& !aliases.setsOwn(caseName))
					ModuleCanonicalizer.addExpressionAlias(aliases, caseName, target);
			var aliasStart = typeAliases.length,
				enumStart = enums.length,
				abstractStart = abstracts.length,
				interfaceStart = interfaces.length,
				classStart = classes.length,
				functionStart = functions.length,
				programFunctionStart = programFunctions.length;
			// The module's functions and variables are named before any of its declarations is, so an abstract's or enum's
			// methods reach them as a class's do. Module-level variables (static fields of the module's class, see
			// ModuleFields) are named as the functions are.
			for (fn in ast.functions)
				locals.set(fn.name, true);
			if (ast.fields != null)
				for (field in ast.fields)
					locals.set(field.name, true);
			for (interfaceDecl in ast.interfaces)
				interfaces.push(ModuleCanonicalizer.canonicalInterface(interfaceDecl, aliases, ast.packageName,
					name, entryModule, locals));
			for (alias in ast.aliases)
				typeAliases.push(ModuleCanonicalizer.canonicalAlias(alias, aliases, ast.packageName));
			for (enumDecl in ast.enums)
				enums.push(ModuleCanonicalizer.canonicalEnum(enumDecl, aliases, ast.packageName, name, entryModule,
					locals));
			for (abstractDecl in ast.abstracts) {
				var canonicalAbstract = ModuleCanonicalizer.canonicalAbstract(abstractDecl, aliases, ast.packageName,
					name, entryModule, locals);
				abstracts.push(canonicalAbstract);
				for (method in canonicalAbstract.methods) {
					var qualified = canonicalAbstract.name + "." + method.name;
					functions.push(AstFunctions.withName(method, qualified));
					owners.set(qualified, name);
					LambdaCollector.collect(method.statements, qualified, name, generatedByModule);
				}
			}
			var canonicalFunctions:Array<AstFunction>;
			if (state.canonicalRevision == state.revision && state.canonicalEntry == entryModule
				&& state.canonicalAliasRevision == aliasRevision) {
				canonicalFunctions = state.canonicalFunctions;
				for (use in state.canonicalFunctionNamespaceUses)
					namespaceUses.push(use);
			} else {
				state = context.state.writableState(name, rollbackModules);
				var functionUses:Array<AliasTable.ModuleNamespaceUse> = [];
				aliases.recordNamespaceUses(functionUses);
				canonicalFunctions = [
					for (fn in ast.functions)
						ModuleCanonicalizer.canonicalFunction(fn, name, entryModule, locals, null, aliases)
				];
				aliases.recordNamespaceUses(namespaceUses);
				for (use in functionUses)
					namespaceUses.push(use);
				state.canonicalFunctionNamespaceUses = functionUses;
				state.canonicalFunctions = canonicalFunctions;
				state.canonicalRevision = state.revision;
				state.canonicalEntry = entryModule;
				state.canonicalAliasRevision = aliasRevision;
			}
			for (canonical in canonicalFunctions) {
				functions.push(canonical);
				programFunctions.push(canonical);
				owners.set(canonical.name, name);
				LambdaCollector.collect(canonical.statements, canonical.name, name, generatedByModule);
			}
			for (classDecl in ast.classes) {
				var className = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name),
					classAliases = aliases.child();
				for (field in classDecl.fields)
					if (constructorTargets.exists(field.name)
						&& classAliases.get(field.name) == constructorTargets.get(field.name))
						classAliases.remove(field.name);
				for (parameter in classDecl.typeParameters)
					classAliases.set(parameter, parameter);
				var parsedBase = classDecl.base,
					canonicalBase:Null<compiler.syntax.Ast.AstType> = null;
				if (parsedBase != null)
					canonicalBase = ModuleCanonicalizer.canonicalType(parsedBase, classAliases,
						classDecl.typeParameters);
				var parsedMethods = classDecl.methods;
				var baseName = nominalTypeName(canonicalBase);
				if (baseName != null && discoveryPrefixes.exists(baseName)) {
					var prefixes = discoveryPrefixes.get(baseName);
					discoveryPrefixes.set(className, prefixes);
					parsedMethods = discoveredMethods(classDecl, className, prefixes);
				}
				var classMethods:Array<AstFunction> = [];
				for (method in parsedMethods) {
					var canonical = ModuleCanonicalizer.canonicalFunction(method, name, entryModule, locals,
						className + "." + method.name, classAliases);
					functions.push(canonical);
					classMethods.push(AstFunctions.withName(canonical, method.name));
					owners.set(canonical.name, name);
					LambdaCollector.collect(canonical.statements, canonical.name, name, generatedByModule);
				}
				var canonicalFields:Array<compiler.syntax.Ast.AstField> = [];
				for (field in classDecl.fields) {
					var initializer = ModuleCanonicalizer.canonicalOptionalExpression(field.initializer, name,
						entryModule, locals, classAliases);
					if (initializer != null)
						LambdaCollector.collectExpression(initializer, InitializerUnit.of(className, field.name), name,
							generatedByModule);
					canonicalFields.push({
						name: field.name,
						visibility: field.visibility,
						metadata: ModuleCanonicalizer.canonicalMetadata(field.metadata, name, entryModule, locals,
							classAliases),
						// An unannotated field's type is its initializer's, typed on demand (`DeclarationTypeTable`).
						type: field.type == null ? null : ModuleCanonicalizer.canonicalType(field.type, classAliases,
							classDecl.typeParameters),
						initializer: initializer,
						readAccess: field.readAccess,
						writeAccess: field.writeAccess,
						isStatic: field.isStatic,
						isInline: field.isInline,
						isFinal: field.isFinal,
						span: field.span,
						declarationSpan: field.declarationSpan
					});
				}
				classes.push({
					name: className,
					isStruct: classDecl.isStruct,
					isExtern: classDecl.isExtern,
					typeParameters: classDecl.typeParameters,
					typeConstraints: classDecl.typeConstraints,
					visibility: classDecl.visibility,
					metadata: ModuleCanonicalizer.canonicalMetadata(classDecl.metadata, name, entryModule, locals,
						classAliases),
					base: canonicalBase,
					interfaces: [
						for (interfaceType in classDecl.interfaces)
							ModuleCanonicalizer.canonicalType(interfaceType, classAliases, classDecl.typeParameters)
					],
					fields: canonicalFields,
					methods: classMethods,
					span: classDecl.span
				});
				owners.set(className + ".new", name);
			}
			state = context.state.writableState(name, rollbackModules);
			state.canonicalAliases = typeAliases.slice(aliasStart);
			state.canonicalEnums = enums.slice(enumStart);
			state.canonicalAbstracts = abstracts.slice(abstractStart);
			state.canonicalInterfaces = interfaces.slice(interfaceStart);
			state.canonicalClasses = classes.slice(classStart);
			state.canonicalAllFunctions = functions.slice(functionStart);
			state.canonicalNamespaceUses = namespaceUses;
			state.canonicalProgramFunctions = programFunctions.slice(programFunctionStart);
			var generated = generatedByModule.get(name);
			state.canonicalGeneratedFunctions = generated == null
				? [] : [for (functionName in generated.keys()) functionName];
			DeclarationPrints.update(facts, before, canonicalContribution(state), sameScope);
			state.canonicalScope = scope;
			// A unit that copied syntax from this module's file (a default argument) names the file's text.
			var snapshot = facts.existing(FactAspect.Snapshot, state.source.path);
			if (snapshot >= 0 && (state.lastGoodSource == null || state.lastGoodSource.text != state.source.text))
				facts.changed(snapshot);
			contributionRebuildMs += Sys.time() * 1000.0 - contributionStartedAt;
		}

		// A newly matching typedef can change a structural codec even when its caller never names the typedef.
		var previousSemantic = context.state.semanticProgram;
		if (previousSemantic != null) {
			var previousAliases = previousSemantic.program.aliases;
			var sameAliases = previousAliases.length == typeAliases.length;
			if (sameAliases)
				for (index in 0...typeAliases.length)
					if (previousAliases[index] != typeAliases[index]) {
						sameAliases = false;
						break;
					}
			if (!sameAliases) {
				var before:Null<Map<String, Array<AstTypeAlias>>> = null;
				var after:Null<Map<String, Array<AstTypeAlias>>> = null;
				facts.forEach(FactAspect.WireAliases, (id, key) -> {
					before = before ?? compiler.types.DeclarationIndex.indexWireAliases(previousAliases);
					after = after ?? compiler.types.DeclarationIndex.indexWireAliases(typeAliases);
					var left = before.get(key) ?? [], right = after.get(key) ?? [];
					if (left.length != right.length) {
						facts.changed(id);
						return;
					}
					for (index in 0...right.length)
						if (left[index].name != right[index].name) {
							facts.changed(id);
							return;
						}
				});
			}
		}

		var canonicalizedAt = Sys.time() * 1000.0;
		for (module => lambdaNames in generatedByModule)
			for (lambdaName in lambdaNames.keys())
				owners.set(lambdaName, module);
		// A class without a constructor has its base class's: give it one, so it is typed, tracked and invalidated like any other.
		// Its signature is its base constructor's, so its signature fact goes through that one.
		// The functions made from other declarations, which appear and go with them, in a module no edit touched.
		var derived:Array<String> = [], derivedClasses:Map<String, AstClass> = [];
		for (constructor in ImplicitConstructors.add(classes)) {
			var qualified = constructor.owner + ".new";
			derivedClasses.set(constructor.owner, constructor.declaration);
			functions.push(AstFunctions.withName(constructor.method, qualified));
			derived.push(qualified);
			facts.setDependencies(facts.id(FactAspect.Signature, qualified),
				[facts.id(FactAspect.Signature, constructor.base + ".new")]);
		}
		// A class that implements an interface with variables has their hidden accessors (`InterfaceFieldAccessors`): typed, tracked
		// and invalidated as its own methods. An accessor's signature is the interface variable's, which the class's members name.
		for (accessor in InterfaceFieldAccessors.add(classes, interfaces)) {
			var qualified = accessor.owner + "." + accessor.method.name;
			derivedClasses.set(accessor.owner, accessor.declaration);
			functions.push(AstFunctions.withName(accessor.method, qualified));
			owners.set(qualified, owners.get(accessor.owner + ".new"));
			derived.push(qualified);
			facts.setDependencies(facts.id(FactAspect.Signature, qualified),
				[facts.id(FactAspect.Members, accessor.owner)]);
		}

		// Purity and no-return are whole-program facts over the canonical program, kept up to date with it: each answer a typed body
		// read (`FactAspect.Purity`, `FactAspect.NoReturn`) that moves moves its readers, which are typed again.
		var purity = context.state.purity;
		purity.update(modules, names, derivedClasses, derived, owners);
		if (context.options.checkReuse)
			checkPurity(purity, classes, interfaces, enums, abstracts, typeAliases, programFunctions);

		var invalid:Map<String, Bool> = [],
			invalidationReasons:Map<String, Array<InvalidationReason>> = [],
			initialBuild = true;
		for (moduleName in names) {
			if (!modules.exists(moduleName))
				continue;
			var state = modules.get(moduleName);
			if (state.lastGoodRevision != 0)
				initialBuild = false;
		}
		// Once units were typed in great number (the first build), what they read is filtered again before an edit needs it.
		facts.refreshReaders();
		if (initialBuild) {
			for (fn in functions)
				invalidate(invalid, invalidationReasons, fn.name, SourceRevision, owners.get(fn.name));
			context.state.unitsCheckedAt = facts.changeCount;
			context.state.unitsCheckedIn = [for (moduleName in names) moduleName => true];
			context.state.unitsPending = [];
		} else if (facts.changedInBuild()) {
			// A unit is typed again when a fact it read, or one that fact goes through, changed after it was typed. When no fact
			// changed in this build, every unit is current. Only the build's modules' units are checked: another module's bodies are
			// not part of this program, and are checked when a build has it again. Every unit was current when the units of the
			// modules last checked were, so only those that read a fact changed since can have changed (`unitsReading`).
			var inBuild:Map<String, Bool> = [for (moduleName in names) moduleName => true];
			var checkedIn = context.state.unitsCheckedIn, sinceChecked = checkedIn != null;
			if (checkedIn != null)
				for (moduleName in names)
					if (!checkedIn.exists(moduleName))
						sinceChecked = false;
			// A unit found changed and not typed again since (an initializer whose field is gone) is changed still.
			var candidates = sinceChecked ? facts.unitsReading(context.state.unitsCheckedAt) : null,
				pending = context.state.unitsPending;
			if (candidates != null && pending.length > 0) {
				var listed:Map<Int, Bool> = [for (id in candidates) id => true];
				for (id in pending)
					if (!listed.exists(id))
						candidates.push(id);
				candidates.sort((left, right) -> left - right);
			}
			var changedUnits:Array<Int> = [];
			if (context.options.checkReuse && candidates != null)
				checkUnitsReading(facts, candidates, inBuild);
			function check(id:Int):Void {
				var record = facts.unitRecord(id);
				if (record == null || !inBuild.exists(record.module))
					return;
				var state = modules.get(record.module);
				if (state == null)
					return;
				var changed = facts.firstChanged(record);
				if (changed < 0)
					return;
				var unit = facts.name(id);
				// A unit the program no longer has keeps no record.
				if (!unitExists(unit, owners, state)) {
					facts.removeUnit(id);
					return;
				}
				changedUnits.push(id);
				var reason = readReason(unit, facts.aspect(changed), facts.name(changed));
				invalidate(invalid, invalidationReasons, unit, reason.kind, facts.name(changed), null, reason.via);
			}
			if (candidates != null) {
				for (id in candidates)
					check(id);
			} else {
				for (id in 0...facts.resultLimit)
					check(id);
			}
			context.state.unitsCheckedAt = facts.changeCount;
			context.state.unitsCheckedIn = inBuild;
			context.state.unitsPending = changedUnits;
			// A function a change to another declaration made (an implicit constructor, an interface variable's accessor) and
			// never typed has nothing to be current with. Any other function is new only in a module that changed, which is typed
			// again as a whole (below).
			for (name in derived) {
				var owner = owners.get(name), state = owner == null ? null : modules.get(owner);
				if (state != null && !hasUnitRecord(facts, name, owner) && !state.typedFunctions.exists(name)
					&& !invalid.exists(name))
					invalidate(invalid, invalidationReasons, name, SourceRevision, owner, null, "new");
			}
		}
		// Rehydrated modules can retain field initializer fingerprints without
		// retaining the generated constructor body. Treat that missing body as
		// invalidated so normal typing and publication rebuild it.
		for (classDecl in classes) {
			var constructorName = classDecl.name + ".new";
			var owner = owners.get(constructorName);
			var state = owner == null ? null : modules.get(owner);
			if (state == null || state.irFunctions.exists(constructorName))
				continue;
			var declaredConstructor = false;
			for (method in classDecl.methods)
				if (method.name == "new")
					declaredConstructor = true;
			if (declaredConstructor)
				continue;
			if (ImplicitConstructors.hasInstanceInitializers(classDecl))
				invalidate(invalid, invalidationReasons, constructorName, SourceRevision, owner);
		}
		// A call may resolve to a static extension without its body naming it (`text.trim()` after `using StringTools`). When the
		// extensions a module's code sees change, every body of the module is typed again.
		for (moduleName in names) {
			var moduleState = modules.get(moduleName);
			if (moduleState == null)
				continue;
			var key = staticExtensions.keyOfModule(moduleName);
			if (moduleState.staticExtensionKey == key)
				continue;
			context.state.writableState(moduleName, rollbackModules).staticExtensionKey = key;
			for (fn in functions)
				if (owners.get(fn.name) == moduleName)
					invalidate(invalid, invalidationReasons, fn.name, StaticExtensions, moduleName);
		}
		var invalidated:Map<String, Bool> = [];
		for (name in invalid.keys())
			invalidated.set(name, true);
		// Semantic indexes are replaced as module-sized snapshots. If one function
		// changes meaning, or its source revision changes, refresh every function in
		// that module without reporting the unchanged functions as invalidated.
		var invalidModules:Map<String, Bool> = [];
		for (functionName in invalid.keys()) {
			var owner = owners.get(functionName);
			if (owner != null)
				invalidModules.set(owner, true);
		}
		for (moduleName in names)
			if (modules.exists(moduleName)
				&& modules.get(moduleName).lastGoodRevision != modules.get(moduleName).revision)
				invalidModules.set(moduleName, true);
		for (fn in functions) {
			var owner = owners.get(fn.name);
			if (owner != null && invalidModules.exists(owner) && !invalid.exists(fn.name)) {
				// The refresh exists to rebuild a module's semantic index, which only editor services read. Without one, a
				// function that was typed and lowered from this revision of its module's source has nothing to redo: its
				// body, spans and dependencies are unchanged (anything that did change is invalid by another reason).
				if (!refreshUnchangedModules && typedAtCurrentRevision(modules.get(owner), fn.name))
					continue;
				invalidate(invalid, invalidationReasons, fn.name, ModuleSemanticSnapshot, owner);
			}
		}
		var selected:Map<String, Bool> = [];
		for (name in invalid.keys())
			selected.set(name, true);
		var entryPoint = context.state.executableEntryPoint(entryModule);
		var canonicalProgram:AstProgram = {
			packageName: null,
			imports: [],
			aliases: typeAliases,
			enums: enums,
			abstracts: abstracts,
			interfaces: interfaces,
			classes: classes,
			functions: programFunctions
		};
		var invalidatedAt = Sys.time() * 1000.0;
		return {
			canonicalProgram: canonicalProgram,
			functions: functions,
			owners: owners,
			staticExtensions: staticExtensions,
			generatedByModule: generatedByModule,
			invalidated: invalidated,
			selected: selected,
			invalidations: orderedInvalidations(invalidationReasons),
			entryPoint: entryPoint,
			entrySpan: context.state.executableEntrySpan(entryModule),
			inferredDeclarations: inferredDeclarations,
			facts: {
				pure: purity.pure,
				noReturn: purity.noReturn
			},
			aliasSetupMs: aliasesPreparedAt - startedAt,
			canonicalizationMs: canonicalizedAt - aliasesPreparedAt,
			contributionReuseMs: contributionReuseMs,
			contributionRebuildMs: contributionRebuildMs,
			invalidationMs: invalidatedAt - canonicalizedAt,
			allocatedBytes: #if haxeon hl.Gc.totalAllocated() - allocatedAtStart #elseif hl hl.Gc.stats().totalAllocated
				- allocatedAtStart #else 0.0 #end
		};
	}

	/**
	 * `--check-reuse`: the purity and never-returns answers kept across builds are what inference anew finds over the canonical
	 * program, over the typer's own signature table: purity inferred over any other scope can disagree with what typing relied on.
	 */
	static function checkPurity(purity:ProgramPurity, classes:Array<AstClass>,
			interfaces:Array<compiler.syntax.Ast.AstInterface>, enums:Array<compiler.syntax.Ast.AstEnum>,
			abstracts:Array<compiler.syntax.Ast.AstAbstract>, aliases:Array<compiler.syntax.Ast.AstTypeAlias>,
			programFunctions:Array<AstFunction>):Void {
		var signatures:Map<String, AstFunction> = [];
		SemanticProgram.fillSignatures(interfaces, classes, abstracts, programFunctions, signatures, null);
		purity.check(signatures, [for (decl in classes) decl.name => decl],
			[for (decl in interfaces) decl.name => decl],
			[for (decl in enums) decl.name => decl], [for (decl in abstracts) decl.name => decl],
			[for (decl in aliases) decl.name => decl]);
	}

	/** `--check-reuse`: every unit of the build that read a fact changed after it was typed is among `candidates`, or pending. */
	static function checkUnitsReading(facts:DeclarationFacts, candidates:Array<Int>, inBuild:Map<String, Bool>):Void {
		var found:Map<Int, Bool> = [for (id in candidates) id => true];
		for (id in 0...facts.resultLimit) {
			var record = facts.unitRecord(id);
			if (record == null || !inBuild.exists(record.module) || found.exists(id))
				continue;
			var changed = facts.firstChanged(record);
			if (changed >= 0)
				throw new compiler.core
					.InternalError('--check-reuse: unit ${facts.name(id)} read ${facts.name(changed)} '
					+ '(${facts.aspect(changed)}, changed at ${facts.changedRevision(changed)}, typed at ${record.revision}), '
					+ "which changed but which the changes since the last check do not lead to");
		}
	}

	/** A module's canonical declarations as its state holds them, which `DeclarationPrints` compares. */
	static function canonicalContribution(state:ModuleState):DeclarationPrints.CanonicalContribution
		return {
			aliases: state.canonicalAliases,
			enums: state.canonicalEnums,
			abstracts: state.canonicalAbstracts,
			interfaces: state.canonicalInterfaces,
			classes: state.canonicalClasses,
			functions: state.canonicalAllFunctions
		};

	/**
	 * What a module's canonical declarations are resolved in besides their own text and the names every module sees (the alias
	 * key, compared apart): the module's package, imports, `using`s and the names it declares. Two canonicalizations in the same
	 * scope, with the same alias key, make the same canonical form of the same text.
	 */
	static function scopeKey(ast:AstProgram):String {
		var parts = [ast.packageName == null ? "" : ast.packageName];
		for (imported in ast.imports)
			parts.push("import " + imported.path + (imported.alias == null ? "" : " as " + imported.alias));
		if (ast.usings != null)
			for (used in ast.usings)
				parts.push("using " + used.path);
		for (fn in ast.functions)
			parts.push("function " + fn.name);
		if (ast.fields != null)
			for (field in ast.fields)
				parts.push("var " + field.name);
		for (decl in ast.classes)
			parts.push("class " + decl.name);
		for (decl in ast.interfaces)
			parts.push("interface " + decl.name);
		for (decl in ast.enums)
			parts.push("enum " + decl.name);
		for (decl in ast.abstracts)
			parts.push("abstract " + decl.name);
		for (decl in ast.aliases)
			parts.push("typedef " + decl.name);
		return parts.join(";");
	}

	/** Whether the program still has unit `unit`, whose reads `state` holds: a function, a field initializer or an inline constant. */
	/** Whether `module`'s state holds a record of what unit `unit` read. */
	static function hasUnitRecord(facts:DeclarationFacts, unit:String, module:String):Bool {
		var record = facts.unitRecord(facts.existing(FactAspect.Unit, unit));
		return record != null && record.module == module;
	}

	static function unitExists(unit:String, owners:Map<String, String>, state:ModuleState):Bool {
		if (owners.exists(unit) || state.typedFunctions.exists(unit))
			return true;
		if (StringTools.startsWith(unit, compiler.types.typing.TypingSession.INLINE_CONSTANT_PREFIX))
			return owners.exists(QualifiedName.parentOrEmpty(unit.substr(compiler.types.typing.TypingSession
				.INLINE_CONSTANT_PREFIX.length))
				+ ".new");
		var owner = InitializerUnit.ownerClass(unit);
		return owner != null && owners.exists(owner + ".new");
	}

	/** Why unit `unit` is typed again, for the invalidation report, when it read fact `aspect` of `name`, which changed. */
	static function readReason(unit:String, aspect:FactAspect, name:String):{kind:InvalidationKind,
		via:Null<String>} return switch aspect {
			case Body if (name == unit): {kind: BodyChanged, via: null};
			case Signature if (name == unit): {kind: SignatureChanged, via: null};
			case Body: {kind: GenericOrigin, via: "body"};
			case Signature: {kind: DependencySignature, via: null};
			case Unit: {kind: DependencySignature, via: "unit"};
			case Initializer: {kind: DependencySignature, via: "initializer"};
			case Shape: {kind: StructuralDependency, via: "shape"};
			case Members: {kind: StructuralDependency, via: "members"};
			case Kind: {kind: StructuralDependency, via: "kind"};
			case Case: {kind: StructuralDependency, via: "case"};
			case WireShape: {kind: StructuralDependency, via: "wire-shape"};
			case WireAliases: {kind: StructuralDependency, via: "wire-aliases"};
			case Purity | NoReturn: {kind: PurityDependency, via: null};
			case Snapshot: {kind: SourceRevision, via: "default-argument"};
		};

	static function addSourceAlias(target:Map<String, String>, moduleAliases:Array<{
		sourceName:String,
		declarationName:String
	}>, moduleName:String,
			declarationName:String, packageName:Null<String>):Void {
		var sourceName = ModuleCanonicalizer.sourceDeclarationPath(moduleName, declarationName),
			canonicalName = ModuleCanonicalizer.qualifiedTypeName(packageName, declarationName);
		target.set(sourceName, canonicalName);
		moduleAliases.push({sourceName: sourceName, declarationName: canonicalName});
		// Haxe also permits spelling a module's primary declaration as Module.Module.
		// Keep the source spelling distinct from its canonical package-level type name.
		if (compiler.core.QualifiedName.last(moduleName) == declarationName) {
			var explicitPrimary = moduleName + "." + declarationName;
			target.set(explicitPrimary, canonicalName);
			moduleAliases.push({sourceName: explicitPrimary, declarationName: canonicalName});
		}
	}

	static function typedAtCurrentRevision(state:Null<ModuleState>, name:String):Bool
		return state != null
			&& state.typedFunctions.exists(name)
			&& state.typedSourceRevisions.get(name) == state.revision
			&& (state.irFunctions.exists(name) || state.pendingIrFunctions.exists(name));

	/**
	 * A lambda is retyped with the function it is written in, so a dependency recorded on the lambda invalidates that function.
	 * Lambda names read `$lambda:<enclosing>:<id>`, and the enclosing name can itself be a generic specialization.
	 */
	/**
	 * The canonical names of the declarations of `program` whose type is inferred from their own body or initializer: a field
	 * without a type, and a function without a result type or with an argument without one.
	 */
	static function collectInferredDeclarations(program:AstProgram, moduleName:String, entryModule:String,
			declarations:Map<String, Bool>):Void {
		for (fn in program.functions)
			if (AstFunctions.leavesSignatureToInference(fn))
				declarations.set(moduleName == entryModule && fn.name == "main" ? "main" : moduleName + "." + fn.name,
					true);
		for (classDecl in program.classes) {
			var className = ModuleCanonicalizer.qualifiedTypeName(program.packageName, classDecl.name);
			for (field in classDecl.fields)
				if (field.type == null)
					declarations.set(className + "." + field.name, true);
			for (method in classDecl.methods)
				if (AstFunctions.leavesSignatureToInference(method))
					declarations.set(className + "." + method.name, true);
		}
		for (abstractDecl in program.abstracts) {
			var abstractName = ModuleCanonicalizer.qualifiedTypeName(program.packageName, abstractDecl.name);
			for (method in abstractDecl.methods)
				if (AstFunctions.leavesSignatureToInference(method))
					declarations.set(abstractName + "." + method.name, true);
		}
	}

	/**
	 * The source aliases grouped by the packages they are visible from: an alias is listed under every package `P` that both its source
	 * name and its declaration name start with (`P.`), and under the root package (""). Each group keeps the aliases in the order of
	 * `sourceTypeAliases`, so what a package sees is built exactly as walking all of them would build it.
	 */
	static function indexAliasesByPackage(sourceTypeAliases:Map<String, String>):Map<String, Array<{
		source:String,
		declaration:String
	}>> {
		var index:Map<String, Array<{source:String, declaration:String}>> = [];
		function add(packageName:String, source:String, declaration:String):Void {
			var group = index.get(packageName);
			if (group == null) {
				group = [];
				index.set(packageName, group);
			}
			group.push({source: source, declaration: declaration});
		}
		for (sourceName => declarationName in sourceTypeAliases) {
			add("", sourceName, declarationName);
			var dot = sourceName.indexOf(".");
			while (dot >= 0) {
				if (declarationName.length > dot
					&& declarationName.charCodeAt(dot) == ".".code
					&& StringTools.startsWith(declarationName, sourceName.substr(0, dot)))
					add(sourceName.substr(0, dot), sourceName, declarationName);
				dot = sourceName.indexOf(".", dot + 1);
			}
		}
		return index;
	}

	static function visibleTypeAliases(packageName:String, aliasIndex:Map<String, Array<{
		source:String,
		declaration:String
	}>>,
			cache:Map<String, Map<String, String>>):Map<String, String> {
		if (cache.exists(packageName))
			return cache.get(packageName);
		var result:Map<String, String> = [],
			visiblePackage:Null<String> = packageName;
		while (visiblePackage != null) {
			var currentPackage:String = visiblePackage,
				prefixLength = currentPackage.length == 0 ? 0 : currentPackage.length + 1,
				group = aliasIndex.get(currentPackage);
			if (group != null)
				for (alias in group) {
					var relativeSourceName = alias.source.substring(prefixLength, alias.source.length),
						simpleName = alias.declaration.substring(prefixLength, alias.declaration.length);
					if (!result.exists(relativeSourceName))
						result.set(relativeSourceName, alias.declaration);
					if (simpleName.indexOf(".") < 0 && !result.exists(simpleName))
						result.set(simpleName, alias.declaration);
				}
			var separator = currentPackage.lastIndexOf(".");
			visiblePackage = separator < 0 ? null : currentPackage.substring(0, separator);
		}
		cache.set(packageName, result);
		return result;
	}

	static function invalidate(invalid:Map<String, Bool>, reasons:Map<String, Array<InvalidationReason>>,
			artifact:String, kind:InvalidationKind,
			cause:String, ?causeId:String, ?via:String):Void {
		invalid.set(artifact, true);
		var entries = reasons.get(artifact);
		if (entries == null) {
			entries = [];
			reasons.set(artifact, entries);
		}
		for (entry in entries)
			if (entry.kind == kind && entry.cause == cause && entry.causeId == causeId && entry.via == via)
				return;
		entries.push({
			kind: kind,
			cause: cause,
			causeId: causeId,
			via: via
		});
	}

	static function orderedInvalidations(reasons:Map<String, Array<InvalidationReason>>):Array<InvalidatedArtifact> {
		var names = [for (name in reasons.keys()) name];
		names.sort(Reflect.compare);
		return [for (name in names) {
			artifact: name, reasons: reasons.get(name)
		}];
	}

	/**
	 * Whether a change can alter the contribution of a module whose own source did not change. A contribution is the module's
	 * declarations with every name resolved, which reads its own source, the entry, and the names every module sees: the type
	 * names, enum constructors and module-level variables (the alias key each contribution is kept with). A signature names
	 * nothing new, and neither does a structural change to an interface, typedef, enum, abstract or static field: whatever names
	 * one of those adds or removes changes the key. What the key leaves out are the methods a class discovers
	 * (`@:discoverMethods`), which a subclass in another module takes from its base chain: a class's metadata (a `constraint:`
	 * change) or its base or layout (a change keyed by the class's own name).
	 */
	static function changesDiscoveredMethods(structuralChanged:Map<String, Bool>):Bool {
		for (change in structuralChanged.keys()) {
			var separator = change.indexOf(":");
			if (separator < 0 || change.substring(0, separator) == "constraint")
				return true;
		}
		return false;
	}

	static function declaredDiscoveryPrefixes(classDecl:AstClass):Null<Array<String>> {
		for (metadata in classDecl.metadata)
			if (metadata.name == "discoverMethods") {
				if (metadata.arguments.length == 0)
					throw new CompileError(new Diagnostic(DiagnosticCode.ANNOTATION_OR_SCHEMA,
						"@:discoverMethods requires at least one prefix",
						metadata.span));
				var prefixes:Array<String> = [];
				for (argument in metadata.arguments)
					switch argument {
						case AstExpression.StringLiteral(value, _):
							prefixes.push(value);
						default:
							throw new CompileError(new Diagnostic(DiagnosticCode.ANNOTATION_OR_SCHEMA,
								"@:discoverMethods prefixes must be string literals", metadata.span));
					}
				return prefixes;
			}
		return null;
	}

	static function discoveredMethods(classDecl:AstClass, className:String, prefixes:Array<String>):Array<AstFunction> {
		for (method in classDecl.methods)
			if (method.name == "registerTests")
				return classDecl.methods;
		var statements:Array<AstStatement> = [];
		for (method in classDecl.methods) {
			var discovered = false;
			for (prefix in prefixes)
				if (StringTools.startsWith(method.name, prefix))
					discovered = true;
			if (!discovered)
				continue;
			if (method.isStatic || method.arguments.length != 0)
				throw new CompileError(new Diagnostic(DiagnosticCode.ANNOTATION_OR_SCHEMA,
					'Discovered method "$className.${method.name}" must be a parameterless instance method',
					method.span));
			switch method.result {
				case AstType.VoidType, AstType.InferredType:
				default:
					throw new CompileError(new Diagnostic(DiagnosticCode.ANNOTATION_OR_SCHEMA,
						'Discovered method "$className.${method.name}" must return Void', method.span));
			}
			var receiver = AstExpression.Variable("this", method.span);
			statements.push(AstStatement.Expression(AstExpression.MethodCall(receiver, "addTest", [
				AstExpression.StringLiteral(className + "." + method.name, method.span),
				AstExpression.Member(AstExpression.Variable("this", method.span), method.name, method.span)
			], method.span), method.span));
		}
		var methods = classDecl.methods.copy();
		methods.push({
			name: "registerTests",
			visibility: AstVisibility.Unwritten,
			isStatic: false,
			isExtern: false,
			metadata: [],
			typeParameters: [],
			typeConstraints: [],
			arguments: [],
			result: AstType.VoidType,
			statements: statements,
			span: classDecl.span
		});
		return methods;
	}

	static function nominalTypeName(type:Null<AstType>):Null<String>
		return switch type {
			case AstType.NamedType(name), AstType.AppliedType(name, _): name;
			default: null;
		};

	/** Whether class `decl` declares a static field or method `name`. */
	static function declaresStatic(decl:AstClass, name:String):Bool {
		for (field in decl.fields)
			if (field.isStatic && field.name == name)
				return true;
		for (method in decl.methods)
			if (method.isStatic && method.name == name)
				return true;
		return false;
	}

}
