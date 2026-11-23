package compiler.semantic;

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
import compiler.semantic.ProgramFacts.InferredProgramFacts;

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
	final entrySpan:compiler.core.Source.SourceSpan;

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

/** Canonicalizes reachable declarations and selects functions invalidated by source changes. */
/** The dependency edges of a program walked backwards (`SemanticAssembly.reverseIndexesOf`), each by its target. */
private typedef ReverseIndexes = {
	/** The callers of each function, as the contributions' calls and implicit constructors name them. */
	final calls:Map<String, Array<String>>;

	final bodyDependencies:Map<String, Array<String>>;
	final declarationTypeReads:Map<String, Array<String>>;
	final initializerCalls:Map<String, Array<String>>;

	/** The callers typing recorded for each callee. */
	final typedCalls:Map<String, Array<String>>;
}

class SemanticAssembly {
	public static function run(context:CompilationContext, entryModule:String, token:Null<CancellationToken>,
			rollbackModules:Map<String, ModuleState>,
			names:Array<String>, bodyChanged:Map<String, Bool>, signatureChanged:Map<String, Bool>,
			structuralChanged:Map<String, Bool>,
			refreshUnchangedModules:Bool = true):SemanticAssemblyResult {
		var startedAt = Sys.time() * 1000.0;
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
			generatedByModule:Map<String, Map<String, Bool>> = [],
			genericOrigins:Map<String, Bool> = [];
		var sourceTypeAliases:Map<String, String> = [],
			aliasesByModule:Map<String, Array<{sourceName:String, declarationName:String}>> = [],
			visibleAliasesByPackage:Map<String, Map<String, String>> = [],
			enumCasesByType:Map<String, Array<String>> = [];
		// The declarations whose type is inferred from their own body or initializer.
		var inferredDeclarations:Map<String, Bool> = [],
			inferredInstanceFields:Map<String, String> = [];
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
			collectInferredDeclarations(program, moduleName, entryModule, inferredDeclarations,
				inferredInstanceFields);
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
		var aliasUniverse = [
			for (sourceName => declarationName in sourceTypeAliases)
				sourceName + "=" + declarationName
		];
		for (typeName => caseNames in enumCasesByType)
			for (caseName in caseNames)
				aliasUniverse.push(typeName + "#" + caseName);
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
		var aliasKey = aliasUniverse.join(";");
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
				&& state.canonicalAliasKey == aliasKey) {
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
				for (functionName in state.canonicalGenericOrigins)
					genericOrigins.set(functionName, true);
				if (state.canonicalGeneratedFunctions.length > 0)
					generatedByModule.set(name,
						[for (functionName in state.canonicalGeneratedFunctions) functionName => true]);
				contributionReuseMs += Sys.time() * 1000.0 - contributionStartedAt;
				continue;
			}
			var importedTypes = context.moduleAnalyzer.importAliases(ast.imports),
				locals = LocalScope.ofNames([]),
				aliases = AliasTable.of(importedTypes);
			aliases.useModuleFieldStorage(moduleFieldStorage, moduleTypeStatics, moduleMembers);
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
				if (ModuleAnalyzer.isWildcardImport(importPath))
					continue;
				var importedTypes:Array<String> = [],
					importConstructors:Map<String, String> = [],
					ambiguousImportConstructors:Map<String, Bool> = [];
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
			// Enum constructors imported through their enum type are expression
			// aliases. Install them only after visible type aliases have been
			// collected, so a class in the current/imported package keeps its
			// name in type positions such as `new Tabs()`.
			for (caseName => target in constructorTargets)
				if (!ambiguousConstructors.exists(caseName) && !aliases.exists(caseName))
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
					if (canonicalAbstract.typeParameters.length > 0
						|| (method.typeParameters != null && method.typeParameters.length > 0))
						genericOrigins.set(qualified, true);
					LambdaCollector.collect(method.statements, qualified, name, generatedByModule);
				}
			}
			var canonicalFunctions:Array<AstFunction>;
			if (state.canonicalRevision == state.revision && state.canonicalEntry == entryModule
				&& state.canonicalAliasKey == aliasKey) {
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
				var canonicalCalls:Map<String, Array<String>> = [];
				for (canonical in canonicalFunctions) {
					var calls:Map<String, Bool> = [],
						localAliases:Map<String, String> = [];
					for (statement in canonical.statements)
						SemanticDependencyCollector.scanCalls(statement, calls, localAliases);
					canonicalCalls.set(canonical.name, [for (callee in calls.keys()) callee]);
				}
				state.canonicalFunctions = canonicalFunctions;
				state.canonicalRevision = state.revision;
				state.canonicalEntry = entryModule;
				state.canonicalAliasKey = aliasKey;
				state.canonicalCalls = canonicalCalls;
			}
			for (canonical in canonicalFunctions) {
				functions.push(canonical);
				programFunctions.push(canonical);
				owners.set(canonical.name, name);
				if (canonical.typeParameters != null && canonical.typeParameters.length > 0)
					genericOrigins.set(canonical.name, true);
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
					if (classDecl.typeParameters.length > 0
						|| (method.typeParameters != null && method.typeParameters.length > 0))
						genericOrigins.set(canonical.name, true);
					var calls:Map<String, Bool> = [];
					var aliases:Map<String, String> = [];
					for (statement in canonical.statements)
						SemanticDependencyCollector.scanCalls(statement, calls, aliases);
					LambdaCollector.collect(canonical.statements, canonical.name, name, generatedByModule);
					state.canonicalCalls.set(canonical.name, [for (name in calls.keys()) name]);
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
						isPublic: field.isPublic,
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
					isPrivate: classDecl.isPrivate,
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
			// An alias remains an invalidation node even though typed values use its resolved type.
			for (alias in state.canonicalAliases)
				SemanticDependencyCollector.addTypeDependency(state.semanticDependencies, alias.name,
					SemanticDependencyKind.Layout, alias.type, aliases);
			state.canonicalEnums = enums.slice(enumStart);
			state.canonicalAbstracts = abstracts.slice(abstractStart);
			state.canonicalInterfaces = interfaces.slice(interfaceStart);
			state.canonicalClasses = classes.slice(classStart);
			state.canonicalAllFunctions = functions.slice(functionStart);
			state.canonicalNamespaceUses = namespaceUses;
			state.canonicalProgramFunctions = programFunctions.slice(programFunctionStart);
			state.canonicalGenericOrigins = [
				for (functionName in genericOrigins.keys())
					if (owners.get(functionName) == name) functionName
			];
			var generated = generatedByModule.get(name);
			state.canonicalGeneratedFunctions = generated == null
				? [] : [for (functionName in generated.keys()) functionName];
			contributionRebuildMs += Sys.time() * 1000.0 - contributionStartedAt;
		}

		var canonicalizedAt = Sys.time() * 1000.0;
		for (module => lambdaNames in generatedByModule)
			for (lambdaName in lambdaNames.keys())
				owners.set(lambdaName, module);
		// A class without a constructor has its base class's: give it one, so it is typed, tracked and invalidated like any other.
		var changedSignatures:Map<String, Bool> = [for (name in signatureChanged.keys()) name => true],
			genericClasses:Map<String, Bool> =
				[for (declaration in classes) if (declaration.typeParameters.length > 0) declaration.name => true];
		var implicitConstructors = ImplicitConstructors.add(classes);
		for (constructor in implicitConstructors) {
			var qualified = constructor.owner + ".new";
			functions.push(AstFunctions.withName(constructor.method, qualified));
			if (genericClasses.exists(constructor.owner))
				genericOrigins.set(qualified, true);
		}
		// A class that implements an interface with variables has their hidden accessors (`InterfaceFieldAccessors`): typed, tracked
		// and invalidated as its own methods, through its layout dependency on the interface.
		for (accessor in InterfaceFieldAccessors.add(classes, interfaces)) {
			var qualified = accessor.owner + "." + accessor.method.name;
			functions.push(AstFunctions.withName(accessor.method, qualified));
			owners.set(qualified, owners.get(accessor.owner + ".new"));
			if (genericClasses.exists(accessor.owner))
				genericOrigins.set(qualified, true);
		}

		// Purity and no-return are whole-program facts, but typed bodies are cached between
		// incremental compiles. Recompute both fresh from the current canonical program (cheap:
		// purely syntactic, no type resolution needed) and compare against what each cached
		// body's own typing last recorded asking about. A caller whose depended-upon answer
		// flipped elsewhere is retyped below through the ordinary invalidation propagation, even
		// though neither its own source nor its signature changed.
		var contributions = [
			for (moduleName in names)
				if (modules.exists(moduleName)) modules.get(moduleName).canonicalAllFunctions
		];
		var inferred = context.state.programFacts;
		if (inferred == null || !sameContributions(inferred.contributions, contributions)) {
			inferred = inferProgramFacts(contributions, classes, interfaces, enums, abstracts, programFunctions);
			context.state.programFacts = inferred;
		}
		var freshInferredPure = inferred.facts.pure,
			freshNoReturn = inferred.facts.noReturn,
			isAnnotatedPure = inferred.isAnnotatedPure;
		var purityDrifted:Map<String, Bool> = [];
		for (moduleName in names) {
			if (!modules.exists(moduleName))
				continue;
			var dependencyState = modules.get(moduleName);
			for (caller => record in dependencyState.purityQueries)
				for (callee => wasPure in record)
					if ((freshInferredPure.exists(callee) || isAnnotatedPure(callee)) != wasPure) {
						purityDrifted.set(purityDependencyOwner(caller), true);
						break;
					}
			for (caller => record in dependencyState.noReturnQueries)
				for (callee => wasNoReturn in record)
					if (freshNoReturn.exists(callee) != wasNoReturn) {
						purityDrifted.set(purityDependencyOwner(caller), true);
						break;
					}
		}

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
		if (initialBuild) {
			for (fn in functions)
				invalidate(invalid, invalidationReasons, fn.name, SourceRevision, owners.get(fn.name));
		} else {
			var structuralQueue:Array<String> = [for (change in structuralChanged.keys()) change],
				structuralTargets:Map<String, Bool> = [],
				structuralCursor = 0;
			while (structuralCursor < structuralQueue.length) {
				var change = structuralQueue[structuralCursor++];
				var changedDependency:String = change,
					separator = changedDependency.indexOf(":"),
					target = separator < 0 ? changedDependency : changedDependency.substring(separator + 1,
						changedDependency.length),
					targetId = context.state.semanticWorkspace.resolveTypeSymbolId(target);
				if (targetId == null)
					targetId = context.state.semanticWorkspace.resolveSymbolId(target);
				var targetKey = targetId == null ? target : targetId;
				if (structuralTargets.exists(targetKey))
					continue;
				structuralTargets.set(targetKey, true);
				for (moduleName in names) {
					if (!modules.exists(moduleName))
						continue;
					var dependencyState = modules.get(moduleName);
					for (owner => dependencies in dependencyState.semanticDependencies) {
						// The functions the owner's first dependency on the target invalidated: the rest only say whether a signature
						// names it.
						var invalidatedFunctions:Null<Array<String>> = null;
						for (dependency in dependencies) {
							var functionOwner:String = owner;
							var matches = dependency.targetId != null
								&& targetId != null ? dependency.targetId
								== targetId : SemanticDependencyCollector.sameDependencyTarget(dependency.target,
								target);
							// A type a signature names changed what it stands for (a typedef's fields, say), so the signature did
							// too, though its text did not: its callers are typed against it again.
							var signature = dependency.kind == SemanticDependencyKind.Signature;
							if (matches && invalidatedFunctions != null) {
								if (signature)
									for (name in invalidatedFunctions)
										changedSignatures.set(name, true);
							} else if (matches) {
								invalidate(invalid, invalidationReasons, functionOwner, StructuralDependency, target,
									targetId, Std.string(dependency.kind));
								if (dependency.kind == compiler.modules.ModuleState.SemanticDependencyKind.Layout)
									for (classDecl in classes)
										if (classDecl.name == functionOwner) {
											structuralQueue.push(functionOwner);
											break;
										}
								if (dependency.kind == compiler.modules.ModuleState.SemanticDependencyKind.Layout)
									for (interfaceDecl in interfaces)
										if (interfaceDecl.name == functionOwner) {
											structuralQueue.push(functionOwner);
											break;
										}
								if (dependency.kind == SemanticDependencyKind.Layout)
									for (alias in typeAliases)
										if (alias.name == functionOwner) {
											structuralQueue.push(functionOwner);
											break;
										}
								var matchedFunctions:Array<String> = [];
								for (fn in functions)
									if (fn.name == functionOwner
										|| StringTools.startsWith(fn.name, functionOwner + ".")) {
										invalidate(invalid, invalidationReasons, fn.name, StructuralDependency, target,
											targetId, Std.string(dependency.kind));
										if (signature)
											changedSignatures.set(fn.name, true);
										matchedFunctions.push(fn.name);
									}
								if (matchedFunctions.length > 0)
									invalidatedFunctions = matchedFunctions;
							}
						}
					}
				}
			}
		}
		// An implicit constructor's signature is its base constructor's, so it changes whenever that does, by its text or by a type it
		// names; the class stands for it to callers. Bases come first, so a chain of them follows in one pass.
		for (constructor in implicitConstructors)
			if (changedSignatures.exists(constructor.base + ".new")) {
				changedSignatures.set(constructor.owner + ".new", true);
				changedSignatures.set(constructor.owner, true);
			}
		// A default argument is typed in the declaration's scope but embedded in its caller. Even a comment-only
		// declaration edit changes that syntax's snapshot hash. Refresh exactly the callers which copied it.
		var sourceFiles = [for (state in modules) state.source.path => state.source];
		for (moduleName in names)
			if (modules.exists(moduleName))
				for (caller => sources in modules.get(moduleName).defaultArgumentSources)
					for (path => source in sources)
						if (!sourceFiles.exists(path) || sourceFiles.get(path).text != source.text) {
							invalidate(invalid, invalidationReasons, enclosingFunction(caller), SourceRevision, path,
								null, "default-argument");
							break;
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
			for (field in classDecl.fields)
				if (!field.isStatic && field.initializer != null) {
					invalidate(invalid, invalidationReasons, constructorName, SourceRevision, owner);
					break;
				}
		}
		for (name in bodyChanged.keys())
			invalidate(invalid, invalidationReasons, name, BodyChanged, name);
		// What the invalidation below walks backwards, made only when something is invalid: a build that changed nothing makes none.
		var reverseIndexes:Null<ReverseIndexes> = null;
		function reverse():ReverseIndexes {
			var made = reverseIndexes;
			if (made == null) {
				made = reverseIndexesOf(modules, names, rollbackModules, inferredDeclarations, implicitConstructors);
				reverseIndexes = made;
			}
			return made;
		}
		var helperOriginIndex:Null<Map<String, String>> = null;
		function helperOrigins():Map<String, String> {
			var made = helperOriginIndex;
			if (made == null) {
				made = helperOriginsOf(modules, names);
				helperOriginIndex = made;
			}
			return made;
		}
		// A call may resolve to a static extension without its body naming it (`text.trim()` after `using StringTools`). When the
		// extensions a module's code sees change, every body of the module is typed again, and propagates as any retyped body does.
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
		var genericCallers:Null<Map<String, Array<String>>> = null;
		var work:Array<String> = [for (name in changedSignatures.keys()) name], workCursor = 0;
		for (name in invalid.keys())
			if (helperOrigins().exists(name) || inferredDeclarations.exists(name))
				work.push(name);
		for (name in bodyChanged.keys())
			if (genericOrigins.exists(name)) {
				work.push(name);
				invalidate(invalid, invalidationReasons, name, GenericOrigin, name);
			}
		// An invalidated generic origin loses its cached specializations, and only a retyped caller requests one again,
		// so its callers are invalidated however the origin was (a changed body, or a layout it depends on).
		for (name in [for (name in invalid.keys()) name])
			if (genericOrigins.exists(name) && !bodyChanged.exists(name))
				work.push(name);
		for (name in purityDrifted.keys()) {
			work.push(name);
			invalidate(invalid, invalidationReasons, name, PurityDependency, name);
		}
		while (workCursor < work.length) {
			if (token != null)
				token.check();
			var changed = work[workCursor++];
			if (changedSignatures.exists(changed))
				invalidate(invalid, invalidationReasons, changed, SignatureChanged, changed,
					context.state.semanticWorkspace.resolveSymbolId(changed));
			else if (!invalid.exists(changed))
				invalidate(invalid, invalidationReasons, changed, DependencySignature, changed);
			var changedId = context.state.semanticWorkspace.resolveSymbolId(changed);
			// The coarse rule of lazy declaration typing (`LAZY_DECLARATION_TYPING.md`, "Invalidation"): a declaration whose type is
			// inferred and that is typed again for any reason may get another type, so its signature counts as changed, and the
			// readers of its type are typed again in turn.
			if (!changedSignatures.exists(changed) && inferredDeclarations.exists(changed)) {
				changedSignatures.set(changed, true);
				var constructor = inferredInstanceFields.get(changed);
				if (constructor != null && !invalid.exists(constructor)) {
					work.push(constructor);
					invalidate(invalid, invalidationReasons, constructor, DependencySignature, changed, changedId,
						Std.string(SemanticDependencyKind.Initializer));
				}
			}
			// A field's initializer is a unit of its own (`Class.__init.x`): what it read can change the type of its field.
			var initialized = InitializerUnit.field(changed);
			if (initialized != null && inferredDeclarations.exists(initialized) && !invalid.exists(initialized)) {
				work.push(initialized);
				invalidate(invalid, invalidationReasons, initialized, DependencySignature, changed, changedId,
					Std.string(SemanticDependencyKind.DeclarationType));
			}
			var helperOrigin = helperOrigins().get(changed);
			if (helperOrigin != null && !invalid.exists(helperOrigin)) {
				work.push(helperOrigin);
				invalidate(invalid, invalidationReasons, helperOrigin, DependencySignature, changed, changedId,
					"generated-helper");
			}
			// A caller is typed against its callee's signature, and lowered with the defaults of the arguments it omits, so it is
			// retyped when that signature changes, as Haxe types it again. A callee only retyped (its body, or a callee of its own,
			// changed) keeps its signature and leaves its callers alone; one whose signature is inferred counts as changed above.
			// A generic origin's callers are retyped however it was invalidated: they request its dropped specializations again.
			var callersRetyped = changedSignatures.exists(changed) || genericOrigins.exists(changed);
			if (callersRetyped && changedId != null && reverse().bodyDependencies.exists(changedId))
				for (ownerName in reverse().bodyDependencies.get(changedId)) {
					var owner = enclosingFunction(ownerName);
					if (!invalid.exists(owner)) {
						work.push(owner);
						invalidate(invalid, invalidationReasons, owner, DependencySignature, changed, changedId,
							Std.string(compiler.modules.ModuleState.SemanticDependencyKind.Body));
					}
				}
			if (changedSignatures.exists(changed)) {
				var readers = reverse().declarationTypeReads.get(changed);
				if (readers != null)
					for (reader in readers) {
						var owner = enclosingFunction(reader);
						if (!invalid.exists(owner)) {
							work.push(owner);
							invalidate(invalid, invalidationReasons, owner, DependencySignature, changed, changedId,
								Std.string(SemanticDependencyKind.DeclarationType));
						}
					}
				// A field initializer is typed with its class in every build, but its field's type is inferred from what it calls.
				for (key in (changedId == null ? [changed] : [changed, changedId])) {
					var fields = reverse().initializerCalls.get(key);
					if (fields != null)
						for (field in fields)
							if (!invalid.exists(field)) {
								work.push(field);
								invalidate(invalid, invalidationReasons, field, DependencySignature, changed, changedId,
									Std.string(SemanticDependencyKind.Initializer));
							}
				}
			}
			if (changedSignatures.exists(changed) && reverse().typedCalls.exists(changed))
				for (caller in reverse().typedCalls.get(changed))
					if (!invalid.exists(caller)) {
						work.push(caller);
						invalidate(invalid, invalidationReasons, caller, DependencySignature, changed, changedId,
							"typed-call");
					}
			if (genericOrigins.exists(changed)) {
				// A call through a local (`context.resourceState(...)`) has no resolvable name before typing, so the callers
				// that must request this origin's dropped specializations again come from the IR they were lowered to.
				if (genericCallers == null)
					genericCallers = callersOfSpecializations(modules, names);
				var requesting = genericCallers.get(changed);
				if (requesting != null)
					for (caller in requesting)
						if (!invalid.exists(caller)) {
							work.push(caller);
							invalidate(invalid, invalidationReasons, caller, DependencySignature, changed, changedId,
								"specialization-request");
						}
			}
			if (callersRetyped && reverse().calls.exists(changed)) {
				var callers = reverse().calls.get(changed);
				for (callerName in callers) {
					var caller = enclosingFunction(callerName);
					if (!invalid.exists(caller)) {
						work.push(caller);
						invalidate(invalid, invalidationReasons, caller, DependencySignature, changed, changedId,
							"provisional-call");
					}
				}
			}
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
				pure: freshInferredPure,
				noReturn: freshNoReturn
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
	 * Purity and no-return over the canonical program, made of `contributions` (see `InferredProgramFacts`), over the typer's own
	 * signature table: purity inferred over any other scope can disagree with what typing relied on, and every cached body then
	 * looks drifted on every edit.
	 */
	static function inferProgramFacts(contributions:Array<Array<AstFunction>>, classes:Array<AstClass>,
			interfaces:Array<compiler.syntax.Ast.AstInterface>, enums:Array<compiler.syntax.Ast.AstEnum>,
			abstracts:Array<compiler.syntax.Ast.AstAbstract>,
			programFunctions:Array<AstFunction>):InferredProgramFacts {
		var purityScopeClasses:Map<String, AstClass> = [for (classDecl in classes) classDecl.name => classDecl];
		var purityScopeInterfaces:Map<String, compiler.syntax.Ast.AstInterface> =
			[for (interfaceDecl in interfaces) interfaceDecl.name => interfaceDecl];
		var purityScopeEnums:Map<String, compiler.syntax.Ast.AstEnum> =
			[for (enumDecl in enums) enumDecl.name => enumDecl];
		var purityScopeAbstracts:Map<String, compiler.syntax.Ast.AstAbstract> =
			[for (decl in abstracts) decl.name => decl];
		var purityScopeSignatures:Map<String, AstFunction> = [];
		SemanticProgram.fillSignatures(interfaces, classes, abstracts, programFunctions, purityScopeSignatures, null);
		var isAnnotatedPure =
			function(candidate:String):Bool return compiler.runtime.CompilerIntrinsics.isPure(candidate)
			|| compiler.types.analysis.PurityAnnotations.hasPureAnnotation(candidate, purityScopeSignatures,
			purityScopeClasses);
		var isTypeName = function(candidate:String):Bool return compiler.types.analysis.PurityAnnotations
			.isTypeName(candidate, purityScopeClasses,
			purityScopeInterfaces, purityScopeEnums, purityScopeAbstracts);
		return {
			contributions: contributions,
			facts: {
				pure: compiler.types.analysis.PurityInference.infer(purityScopeSignatures, purityScopeClasses,
					purityScopeAbstracts, purityScopeEnums, isAnnotatedPure, isTypeName),
				noReturn: compiler.types.analysis.NoReturnDeclarations.declared(purityScopeSignatures)
			},
			isAnnotatedPure: isAnnotatedPure
		};
	}

	/** Whether two programs are made of the same module contributions, in the same order. */
	static function sameContributions(previous:Array<Array<AstFunction>>, current:Array<Array<AstFunction>>):Bool {
		if (previous.length != current.length)
			return false;
		for (index in 0...current.length)
			if (previous[index] != current[index])
				return false;
		return true;
	}

	/**
	 * The program's dependency edges walked backwards, from the modules' records: the syntactic calls of each contribution function
	 * (`dependencyCalls`) and each implicit constructor's call of its base, the body, declaration-type and initializer dependencies,
	 * and the calls typing recorded.
	 */
	static function reverseIndexesOf(modules:Map<String, ModuleState>, names:Array<String>,
			rollbackModules:Map<String, ModuleState>, inferredDeclarations:Map<String, Bool>,
			implicitConstructors:Array<{owner:String, base:String, method:AstFunction}>):ReverseIndexes {
		var reverseCalls:Map<String, Array<String>> = [];
		for (moduleName in names) {
			var state = modules.get(moduleName);
			if (state == null)
				continue;
			for (fn in state.canonicalAllFunctions) {
				var fallbackCalls = state.canonicalCalls.get(fn.name);
				for (callee in dependencyCalls(state, rollbackModules, fn.name,
					fallbackCalls == null ? [] : fallbackCalls))
					addReverseCall(reverseCalls, callee, fn.name);
			}
		}
		for (implicit in implicitConstructors)
			addReverseCall(reverseCalls, implicit.base + ".new", implicit.owner + ".new");
		var reverseBodyDependencies:Map<String, Array<String>> = [],
			reverseDeclarationTypeReads:Map<String, Array<String>> = [],
			reverseInitializerCalls:Map<String, Array<String>> = [];
		for (moduleName in names) {
			if (!modules.exists(moduleName))
				continue;
			for (owner => dependencies in modules.get(moduleName).semanticDependencies)
				for (dependency in dependencies)
					if (dependency.kind == compiler.modules.ModuleState.SemanticDependencyKind.Body
						&& dependency.targetId != null) {
						var dependents = reverseBodyDependencies.get(dependency.targetId);
						if (dependents == null) {
							dependents = [];
							reverseBodyDependencies.set(dependency.targetId, dependents);
						}
						dependents.push(owner);
					} else if (dependency.kind == SemanticDependencyKind.DeclarationType)
						addReverseCall(reverseDeclarationTypeReads, dependency.target, owner);
					else if (dependency.kind == SemanticDependencyKind.Initializer
						&& inferredDeclarations.exists(owner))
						addReverseCall(reverseInitializerCalls,
							dependency.targetId == null ? dependency.target : dependency.targetId, owner);
		}
		// Before typing, `gate.worst()` only names the local `gate`, so the syntactic dependencies above cannot tell that a
		// function calls `Gate.worst`. Typing can: it records the callee of every call against the function being typed (see
		// `TypingSession.purityQueries`, kept for the purity drift check and used here for the callee alone). Walked backwards,
		// that finds the functions to retype when a callee's signature changes, such as a method gaining an optional parameter,
		// which every caller still type-checks against but must be lowered to again.
		var reverseTypedCalls:Map<String, Array<String>> = [];
		for (moduleName in names) {
			if (!modules.exists(moduleName))
				continue;
			for (caller => record in modules.get(moduleName).purityQueries)
				for (callee in record.keys()) {
					var callers = reverseTypedCalls.get(callee);
					if (callers == null) {
						callers = [];
						reverseTypedCalls.set(callee, callers);
					}
					callers.push(purityDependencyOwner(caller));
				}
		}
		return {
			calls: reverseCalls,
			bodyDependencies: reverseBodyDependencies,
			declarationTypeReads: reverseDeclarationTypeReads,
			initializerCalls: reverseInitializerCalls,
			typedCalls: reverseTypedCalls
		};
	}

	/**
	 * The origin of each generated helper the modules hold. A generated helper can depend on a type that its source function does
	 * not mention in its signature. When that helper is invalidated, its origin is retyped so the helper and its dependencies are
	 * requested again.
	 */
	static function helperOriginsOf(modules:Map<String, ModuleState>, names:Array<String>):Map<String, String> {
		var helperOrigins:Map<String, String> = [];
		for (moduleName in names)
			if (modules.exists(moduleName))
				for (name => fn in modules.get(moduleName).typedFunctions)
					if (fn.originKind == compiler.types.TypedAst.FunctionOriginKind.Helper && fn.origin != null)
						helperOrigins.set(name, fn.origin);
		return helperOrigins;
	}

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

	/** The functions whose lowered bodies call or refer to a specialization, by the generic function it was made from. */
	static function callersOfSpecializations(modules:Map<String, ModuleState>,
			names:Array<String>):Map<String, Array<String>> {
		var result:Map<String, Array<String>> = [];
		for (moduleName in names) {
			var state = modules.get(moduleName);
			if (state == null)
				continue;
			for (functionName => fn in state.irFunctions) {
				var caller = enclosingFunction(functionName),
					seen:Map<String, Bool> = [];
				function refer(target:String):Void {
					var origin = genericOrigin(target);
					if (origin == null || seen.exists(origin))
						return;
					seen.set(origin, true);
					var callers = result.get(origin);
					if (callers == null) {
						callers = [];
						result.set(origin, callers);
					}
					callers.push(caller);
				}
				// A function kept as its body alone is read from the body, not decoded.
				var body = fn.body;
				if (body != null) {
					for (block in 0...body.blockCount()) {
						var row = body.firstRow(block);
						while (row >= 0) {
							switch body.opcode(row) {
								case compiler.ir.model.IrOpcode.Call, compiler.ir.model.IrOpcode.StaticClosure,
									compiler.ir.model.IrOpcode.InstanceClosure:
									refer(body.symbol(row).name);
								default:
							}
							row = body.nextRow(row);
						}
					}
					continue;
				}
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case Call(_, name, _), StaticClosure(_, name), InstanceClosure(_, name, _):
								refer(name.name);
							default:
						}
			}
		}
		return result;
	}

	/** The generic function or method a call or closure target was made from, or null when the target is not generic. */
	static function genericOrigin(target:String):Null<String> {
		if (GeneratedNames.isSpecialization(target))
			return enclosingFunction(target);
		// A bound method (a method value): made from its owner's method.
		var reference = compiler.ir.gen.IrMethodReferences.of(target);
		return reference == null ? null : reference.owner + "." + reference.member;
	}

	/**
	 * A lambda is retyped with the function it is written in, so a dependency recorded on the lambda invalidates that function.
	 * Lambda names read `$lambda:<enclosing>:<id>`, and the enclosing name can itself be a generic specialization.
	 */
	/**
	 * The canonical names of the declarations of `program` whose type is inferred from their own body or initializer: a field
	 * without a type, and a function without a result type or with an argument without one. Each such instance field names the
	 * constructor that holds its initializer.
	 */
	static function collectInferredDeclarations(program:AstProgram, moduleName:String, entryModule:String,
			declarations:Map<String, Bool>, instanceFields:Map<String, String>):Void {
		for (fn in program.functions)
			if (AstFunctions.leavesSignatureToInference(fn))
				declarations.set(moduleName == entryModule && fn.name == "main" ? "main" : moduleName + "." + fn.name,
					true);
		for (classDecl in program.classes) {
			var className = ModuleCanonicalizer.qualifiedTypeName(program.packageName, classDecl.name);
			for (field in classDecl.fields)
				if (field.type == null) {
					declarations.set(className + "." + field.name, true);
					if (!field.isStatic)
						instanceFields.set(className + "." + field.name, className + ".new");
				}
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

	static function enclosingFunction(name:String):String {
		name = LambdaName.outermost(name);
		return GeneratedNames.specializedFunction(name);
	}

	static function addReverseCall(reverseCalls:Map<String, Array<String>>, callee:String, caller:String):Void {
		var callers = reverseCalls.get(callee);
		if (callers == null) {
			callers = [];
			reverseCalls.set(callee, callers);
		}
		callers.push(caller);
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
			artifact:name, reasons:reasons.get(name)
		}];
	}

	/** A purity/no-return answer is recorded against the exact body that asked, which for a
	 * closure is its own `$lambda:origin:identity` name. Only the top-level function is ever
	 * independently retyped, so walk back through any lambda nesting to find it.
	 */
	static function purityDependencyOwner(name:String):String
		return LambdaName.outermost(name);

	/** Prefer the last successfully resolved call graph; syntax calls bootstrap new declarations. */
	static function dependencyCalls(state:ModuleState, rollbackModules:Map<String, ModuleState>, owner:String,
			fallback:Array<String>):Array<String> {
		var previous = rollbackModules.exists(state.name) ? rollbackModules.get(state.name) : state,
			dependencies = previous.semanticDependencies.get(owner),
			resolved:Array<String> = [];
		if (dependencies != null)
			for (dependency in dependencies)
				if (dependency.kind == compiler.modules.ModuleState.SemanticDependencyKind.Body
					&& dependency.targetId != null)
					resolved.push(dependency.target);
		return resolved.length == 0 ? fallback : resolved;
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
					throw new CompileError(new Diagnostic("E1024", "@:discoverMethods requires at least one prefix",
						metadata.span));
				var prefixes:Array<String> = [];
				for (argument in metadata.arguments)
					switch argument {
						case AstExpression.StringLiteral(value, _):
							prefixes.push(value);
						default:
							throw new CompileError(new Diagnostic("E1024",
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
				throw new CompileError(new Diagnostic("E1024",
					'Discovered method "$className.${method.name}" must be a parameterless instance method',
					method.span));
			switch method.result {
				case AstType.VoidType, AstType.InferredType:
				default:
					throw new CompileError(new Diagnostic("E1024",
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
