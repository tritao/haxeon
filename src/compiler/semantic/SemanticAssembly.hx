package compiler.semantic;

import compiler.syntax.Ast;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.compilation.CompilationContext;
import compiler.modules.ModuleState;
import compiler.service.CancellationToken;
import compiler.types.FieldInference;
import compiler.types.SignatureInference;
import compiler.semantic.Invalidation.InvalidatedArtifact;
import compiler.semantic.Invalidation.InvalidationKind;
import compiler.semantic.Invalidation.InvalidationReason;

typedef SemanticAssemblyResult = {
	final canonicalProgram:AstProgram;
	final functions:Array<AstFunction>;
	final owners:Map<String, String>;
	final generatedByModule:Map<String, Map<String, Bool>>;
	final invalidated:Map<String, Bool>;
	final selected:Map<String, Bool>;
	final invalidations:Array<InvalidatedArtifact>;
	final entryPoint:String;
	final aliasSetupMs:Float;
	final canonicalizationMs:Float;
	final contributionReuseMs:Float;
	final contributionRebuildMs:Float;
	final invalidationMs:Float;
	final allocatedBytes:Float;
}

/** Canonicalizes reachable declarations and selects functions invalidated by source changes. */
class SemanticAssembly {
	public static function run(context:CompilationContext, entryModule:String, token:Null<CancellationToken>, rollbackModules:Map<String, ModuleState>,
			names:Array<String>, bodyChanged:Map<String, Bool>, signatureChanged:Map<String, Bool>, structuralChanged:Map<String, Bool>,
			refreshUnchangedModules:Bool = true):SemanticAssemblyResult {
		var startedAt = Sys.time() * 1000.0;
		#if haxeon
		var allocatedAtStart = hl.Gc.totalAllocated();
		#elseif hl
		var allocatedAtStart = hl.Gc.stats().totalAllocated;
		#end
		var contributionReuseMs = 0.0, contributionRebuildMs = 0.0;
		var modules = context.modules;
		var functions:Array<AstFunction> = [],
			programFunctions:Array<AstFunction> = [],
			typeAliases:Array<compiler.syntax.Ast.AstTypeAlias> = [],
			enums:Array<compiler.syntax.Ast.AstEnum> = [],
			enumAbstracts:Array<compiler.syntax.Ast.AstEnumAbstract> = [],
			abstracts:Array<compiler.syntax.Ast.AstAbstract> = [],
			interfaces:Array<compiler.syntax.Ast.AstInterface> = [],
			classes:Array<compiler.syntax.Ast.AstClass> = [],
			owners:Map<String, String> = [],
			generatedByModule:Map<String, Map<String, Bool>> = [],
			reverseCalls:Map<String, Array<String>> = [],
			genericOrigins:Map<String, Bool> = [];
		var sourceTypeAliases:Map<String, String> = [],
			aliasesByModule:Map<String, Array<{sourceName:String, declarationName:String}>> = [],
			visibleAliasesByPackage:Map<String, Map<String, String>> = [],
			enumCasesByType:Map<String, Array<String>> = [];
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
			for (declaration in program.enumAbstracts) {
				var canonicalName = ModuleCanonicalizer.qualifiedTypeName(program.packageName, declaration.name);
				addSourceAlias(sourceTypeAliases, moduleAliases, moduleName, declaration.name, program.packageName);
				enumCasesByType.set(canonicalName, [for (enumCase in declaration.values) enumCase.name]);
			}
			for (declaration in program.abstracts)
				addSourceAlias(sourceTypeAliases, moduleAliases, moduleName, declaration.name, program.packageName);
			for (declaration in program.interfaces)
				addSourceAlias(sourceTypeAliases, moduleAliases, moduleName, declaration.name, program.packageName);
			for (declaration in program.classes)
				addSourceAlias(sourceTypeAliases, moduleAliases, moduleName, declaration.name, program.packageName);
		}
		var aliasUniverse = [
			for (sourceName => declarationName in sourceTypeAliases)
				sourceName + "=" + declarationName
		];
		for (typeName => caseNames in enumCasesByType)
			for (caseName in caseNames)
				aliasUniverse.push(typeName + "#" + caseName);
		aliasUniverse.sort(Reflect.compare);
		var aliasKey = aliasUniverse.join(";");
		var classDeclarations:Map<String, AstClass> = [],
			enumDeclarations:Map<String, compiler.syntax.Ast.AstEnum> = [],
			enumAbstractDeclarations:Map<String, compiler.syntax.Ast.AstEnumAbstract> = [];
		for (moduleName in names)
			if (modules.exists(moduleName)) {
				var parsed = modules.get(moduleName).parsedAst();
				for (enumDecl in parsed.enums)
					enumDeclarations.set(ModuleCanonicalizer.qualifiedTypeName(parsed.packageName, enumDecl.name), enumDecl);
				for (abstractDecl in parsed.enumAbstracts)
					enumAbstractDeclarations.set(ModuleCanonicalizer.qualifiedTypeName(parsed.packageName, abstractDecl.name), abstractDecl);
				for (classDecl in parsed.classes)
					classDeclarations.set(ModuleCanonicalizer.qualifiedTypeName(parsed.packageName, classDecl.name), classDecl);
			}

		var discoveryPrefixes:Map<String, Array<String>> = [];
		for (moduleName in names) {
			if (!modules.exists(moduleName))
				continue;
			var program = modules.get(moduleName).parsedAst();
			for (classDecl in program.classes) {
				var prefixes = declaredDiscoveryPrefixes(classDecl);
				if (prefixes != null)
					discoveryPrefixes.set(ModuleCanonicalizer.qualifiedTypeName(program.packageName, classDecl.name), prefixes);
			}
		}
		var reuseModuleContributions = CompilationContext.mapIsEmpty(signatureChanged) && CompilationContext.mapIsEmpty(structuralChanged);
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
						if (baseName != null && discoveryPrefixes.exists(baseName) && !discoveryPrefixes.exists(classDecl.name)) {
							discoveryPrefixes.set(classDecl.name, discoveryPrefixes.get(baseName));
							discovered = true;
						}
					}
				}
			}
		}
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
				&& state.canonicalAliasKey == aliasKey
				&& state.canonicalAllFunctions.length > 0) {
				for (value in state.canonicalAliases)
					typeAliases.push(value);
				for (value in state.canonicalEnums)
					enums.push(value);
				for (value in state.canonicalEnumAbstracts)
					enumAbstracts.push(value);
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
					var fallbackCalls = state.canonicalCalls.get(fn.name);
					if (fallbackCalls == null)
						fallbackCalls = [];
					for (callee in dependencyCalls(state, rollbackModules, fn.name, fallbackCalls))
						addReverseCall(reverseCalls, callee, fn.name);
				}
				for (fn in state.canonicalProgramFunctions)
					programFunctions.push(fn);
				for (functionName in state.canonicalGenericOrigins)
					genericOrigins.set(functionName, true);
				if (state.canonicalGeneratedFunctions.length > 0)
					generatedByModule.set(name, [for (functionName in state.canonicalGeneratedFunctions) functionName => true]);
				contributionReuseMs += Sys.time() * 1000.0 - contributionStartedAt;
				continue;
			}
			var locals:Map<String, Bool> = [],
				aliases = context.importAliases(ast.imports, ast.importAliases);
			// An explicit import outranks a same-named type elsewhere in the
			// program, such as an unpackaged `Path` shadowing `import nav.Path`.
			// Unpackaged names wait until the current package's own types are in:
			// in `package nav`, a plain `Path` is `nav.Path`, as in Haxe.
			for (sourceName => declarationName in sourceTypeAliases)
				if (sourceName.indexOf(".") >= 0 && !aliases.exists(sourceName))
					aliases.set(sourceName, declarationName);
			var constructorTargets:Map<String, String> = [],
				ambiguousConstructors:Map<String, Bool> = [];
			for (importPath in ast.imports) {
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
				if (aliasesByModule.exists(importPath))
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
			for (importPath in ast.imports) {
				var importedModule = ModuleAnalyzer.importModulePath(importPath);
				if (aliasesByModule.exists(importedModule))
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
			if (visiblePackage != null)
				for (alias => target in visibleTypeAliases(visiblePackage, sourceTypeAliases, visibleAliasesByPackage))
					if (!aliases.exists(alias))
						aliases.set(alias, target);
			for (sourceName => declarationName in sourceTypeAliases)
				if (sourceName.indexOf(".") < 0 && !aliases.exists(sourceName))
					aliases.set(sourceName, declarationName);
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
				enumAbstractStart = enumAbstracts.length,
				abstractStart = abstracts.length,
				interfaceStart = interfaces.length,
				classStart = classes.length,
				functionStart = functions.length,
				programFunctionStart = programFunctions.length;
			for (interfaceDecl in ast.interfaces)
				interfaces.push(ModuleCanonicalizer.canonicalInterface(interfaceDecl, aliases, ast.packageName));
			for (alias in ast.aliases)
				typeAliases.push(ModuleCanonicalizer.canonicalAlias(alias, aliases, ast.packageName));
			for (enumDecl in ast.enums)
				enums.push(ModuleCanonicalizer.canonicalEnum(enumDecl, aliases, ast.packageName));
			for (abstractDecl in ast.enumAbstracts)
				enumAbstracts.push(ModuleCanonicalizer.canonicalEnumAbstract(abstractDecl, aliases, ast.packageName, name, entryModule, locals));
			for (abstractDecl in ast.abstracts) {
				var canonicalAbstract = ModuleCanonicalizer.canonicalAbstract(abstractDecl, aliases, ast.packageName, name, entryModule, locals);
				abstracts.push(canonicalAbstract);
				for (method in canonicalAbstract.methods) {
					var qualified = canonicalAbstract.name + "." + method.name,
						canonicalMethod:AstFunction = {
							name: qualified,
							isStatic: method.isStatic,
							typeParameters: method.typeParameters,
							typeConstraints: method.typeConstraints,
							arguments: method.arguments,
							result: method.result,
							span: method.span,
							statements: method.statements
						};
					functions.push(canonicalMethod);
					owners.set(qualified, name);
					if (canonicalAbstract.typeParameters.length > 0 || (method.typeParameters != null && method.typeParameters.length > 0))
						genericOrigins.set(qualified, true);
					LambdaCollector.collect(method.statements, qualified, name, generatedByModule);
				}
			}
			for (fn in ast.functions)
				locals.set(fn.name, true);
			var canonicalFunctions:Array<AstFunction>;
			if (state.canonicalRevision == state.revision && state.canonicalEntry == entryModule && state.canonicalAliasKey == aliasKey)
				canonicalFunctions = state.canonicalFunctions;
			else {
				state = context.writableState(name, rollbackModules);
				canonicalFunctions = [
					for (fn in ast.functions)
						ModuleCanonicalizer.canonicalFunction(fn, name, entryModule, locals, null, aliases)
				];
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
				for (callee in dependencyCalls(state, rollbackModules, canonical.name, state.canonicalCalls.get(canonical.name))) {
					var callers:Array<String>;
					if (reverseCalls.exists(callee))
						callers = reverseCalls.get(callee);
					else {
						callers = [];
						reverseCalls.set(callee, callers);
					}
					callers.push(canonical.name);
				}
			}
			for (classDecl in ast.classes) {
				var className = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name),
					classAliases:Map<String, String> = [for (alias => target in aliases) alias => target];
				for (field in classDecl.fields)
					if (constructorTargets.exists(field.name) && classAliases.get(field.name) == constructorTargets.get(field.name))
						classAliases.remove(field.name);
				for (parameter in classDecl.typeParameters)
					classAliases.set(parameter, parameter);
				var parsedBase = classDecl.base,
					canonicalBase:Null<compiler.syntax.Ast.AstType> = null;
				if (parsedBase != null)
					canonicalBase = ModuleCanonicalizer.canonicalType(parsedBase, classAliases, classDecl.typeParameters);
				var parsedMethods = classDecl.methods;
				var baseName = nominalTypeName(canonicalBase);
				if (baseName != null && discoveryPrefixes.exists(baseName)) {
					var prefixes = discoveryPrefixes.get(baseName);
					discoveryPrefixes.set(className, prefixes);
					parsedMethods = discoveredMethods(classDecl, className, prefixes);
				}
				var classMethods:Array<AstFunction> = [];
				for (parsedMethod in parsedMethods) {
					var method = SignatureInference.inferFieldBoundArguments(parsedMethod, classDecl);
					var canonical = ModuleCanonicalizer.canonicalFunction(method, name, entryModule, locals, className + "." + method.name, classAliases);
					functions.push(canonical);
					classMethods.push({
						name: method.name,
						isStatic: method.isStatic,
						isExtern: method.isExtern,
						metadata: method.metadata,
						typeParameters: method.typeParameters,
						typeConstraints: canonical.typeConstraints,
						arguments: canonical.arguments,
						result: canonical.result,
						span: method.span,
						statements: canonical.statements
					});
					owners.set(canonical.name, name);
					if (classDecl.typeParameters.length > 0 || (method.typeParameters != null && method.typeParameters.length > 0))
						genericOrigins.set(canonical.name, true);
					var calls:Map<String, Bool> = [];
					var aliases:Map<String, String> = [];
					for (statement in canonical.statements)
						SemanticDependencyCollector.scanCalls(statement, calls, aliases);
					LambdaCollector.collect(canonical.statements, canonical.name, name, generatedByModule);
					var fallbackCalls = [for (name in calls.keys()) name];
					state.canonicalCalls.set(canonical.name, fallbackCalls);
					for (callee in dependencyCalls(state, rollbackModules, canonical.name, fallbackCalls)) {
						var callers:Array<String>;
						if (reverseCalls.exists(callee))
							callers = reverseCalls.get(callee);
						else {
							callers = [];
							reverseCalls.set(callee, callers);
						}
						callers.push(canonical.name);
					}
				}
				var canonicalFields:Array<compiler.syntax.Ast.AstField> = [];
				for (field in classDecl.fields) {
					var initializer = ModuleCanonicalizer.canonicalOptionalExpression(field.initializer, name, entryModule, locals, classAliases);
					if (initializer != null)
						LambdaCollector.collectExpression(initializer, className + ".__init", name, generatedByModule);
					canonicalFields.push({
						name: field.name,
						metadata: field.metadata,
						type: ModuleCanonicalizer.canonicalType(FieldInference.resolvedType(field, className, classDeclarations, classAliases,
							enumDeclarations, enumAbstractDeclarations),
							classAliases, classDecl.typeParameters),
						initializer: initializer,
						readAccess: field.readAccess,
						writeAccess: field.writeAccess,
						isStatic: field.isStatic,
						isInline: field.isInline,
						isFinal: field.isFinal,
						span: field.span
					});
				}
				classes.push({
					name: className,
					isExtern: classDecl.isExtern,
					typeParameters: classDecl.typeParameters,
					typeConstraints: classDecl.typeConstraints,
					isPrivate: classDecl.isPrivate,
					metadata: classDecl.metadata,
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
			state = context.writableState(name, rollbackModules);
			state.canonicalAliases = typeAliases.slice(aliasStart);
			state.canonicalEnums = enums.slice(enumStart);
			state.canonicalEnumAbstracts = enumAbstracts.slice(enumAbstractStart);
			state.canonicalAbstracts = abstracts.slice(abstractStart);
			state.canonicalInterfaces = interfaces.slice(interfaceStart);
			state.canonicalClasses = classes.slice(classStart);
			state.canonicalAllFunctions = functions.slice(functionStart);
			state.canonicalProgramFunctions = programFunctions.slice(programFunctionStart);
			state.canonicalGenericOrigins = [
				for (functionName in genericOrigins.keys())
					if (owners.get(functionName) == name) functionName
			];
			var generated = generatedByModule.get(name);
			state.canonicalGeneratedFunctions = generated == null ? [] : [for (functionName in generated.keys()) functionName];
			contributionRebuildMs += Sys.time() * 1000.0 - contributionStartedAt;
		}

		var canonicalizedAt = Sys.time() * 1000.0;
		for (module => lambdaNames in generatedByModule)
			for (lambdaName in lambdaNames.keys())
				owners.set(lambdaName, module);
		// A class without a constructor has its base class's: give it one, so it is typed, tracked and invalidated like any other.
		var changedSignatures:Map<String, Bool> = [for (name in signatureChanged.keys()) name => true];
		for (constructor in ImplicitConstructors.add(classes)) {
			var qualified = constructor.owner + ".new",
				baseConstructor = constructor.base + ".new";
			// Its signature is the base constructor's, so it changes whenever that does; the class stands for it to callers.
			if (changedSignatures.exists(baseConstructor)) {
				changedSignatures.set(qualified, true);
				changedSignatures.set(constructor.owner, true);
			}
			functions.push({
				name: qualified,
				isStatic: false,
				metadata: [],
				arguments: constructor.method.arguments,
				result: constructor.method.result,
				statements: constructor.method.statements,
				span: constructor.method.span
			});
			var callers = reverseCalls.get(baseConstructor);
			if (callers == null) {
				callers = [];
				reverseCalls.set(baseConstructor, callers);
			}
			callers.push(qualified);
			for (declaration in classes)
				if (declaration.name == constructor.owner && declaration.typeParameters.length > 0)
					genericOrigins.set(qualified, true);
		}

		// Purity and no-return are whole-program facts, but typed bodies are cached between
		// incremental compiles. Recompute both fresh from the current canonical program (cheap:
		// purely syntactic, no type resolution needed) and compare against what each cached
		// body's own typing last recorded asking about. A caller whose depended-upon answer
		// flipped elsewhere is retyped below through the ordinary invalidation propagation, even
		// though neither its own source nor its signature changed.
		var purityScopeClasses:Map<String, AstClass> = [for (classDecl in classes) classDecl.name => classDecl];
		var purityScopeInterfaces:Map<String, compiler.syntax.Ast.AstInterface> = [for (interfaceDecl in interfaces) interfaceDecl.name => interfaceDecl];
		var purityScopeEnums:Map<String, compiler.syntax.Ast.AstEnum> = [for (enumDecl in enums) enumDecl.name => enumDecl];
		var purityScopeEnumAbstracts:Map<String, compiler.syntax.Ast.AstEnumAbstract> = [for (decl in enumAbstracts) decl.name => decl];
		var purityScopeAbstracts:Map<String, compiler.syntax.Ast.AstAbstract> = [for (decl in abstracts) decl.name => decl];
		// The typer's own signature table: purity inferred over any other scope can disagree with what typing relied on, and
		// every cached body then looks drifted on every edit.
		var purityScopeSignatures:Map<String, AstFunction> = [];
		SemanticProgram.fillSignatures(interfaces, classes, abstracts, programFunctions, purityScopeSignatures, null);
		var isAnnotatedPure = function(candidate:String):Bool return compiler.runtime.CompilerIntrinsics.isPure(candidate)
			|| compiler.types.analysis.PurityAnnotations.hasPureAnnotation(candidate, purityScopeSignatures, purityScopeClasses);
		var isTypeName = function(candidate:String):Bool return compiler.types.analysis.PurityAnnotations.isTypeName(candidate, purityScopeClasses,
			purityScopeInterfaces, purityScopeEnums, purityScopeEnumAbstracts, purityScopeAbstracts);
		var freshInferredPure = compiler.types.analysis.PurityInference.infer(purityScopeSignatures, purityScopeClasses, purityScopeAbstracts,
			purityScopeEnums, isAnnotatedPure, isTypeName);
		var freshNoReturn = compiler.types.analysis.NoReturnInference.infer(purityScopeSignatures, purityScopeClasses,
			compiler.types.analysis.OverrideAnalysis.overriddenMethods(purityScopeClasses));
		var purityDrifted:Map<String, Bool> = [];
		for (moduleName in names) {
			if (!modules.exists(moduleName))
				continue;
			var dependencyState = modules.get(moduleName);
			for (caller => record in dependencyState.purityQueries)
				for (callee => wasPure in record)
					if ((freshInferredPure.exists(callee) || isAnnotatedPure(callee)) != wasPure) {
						if (Sys.getEnv("HAXEON_EXPLAIN_INVALIDATION") != null && !purityDrifted.exists(purityDependencyOwner(caller)))
							Sys.stderr()
								.writeString("  drift: " + caller + " asked about " + callee + " was=" + wasPure + " inferred="
									+ freshInferredPure.exists(callee) + " annotated=" + isAnnotatedPure(callee) + "\n");
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
			for (change in structuralChanged.keys()) {
				var changedDependency:String = change,
					separator = changedDependency.indexOf(":"),
					target = separator < 0 ? changedDependency : changedDependency.substring(separator + 1, changedDependency.length),
					targetId = context.resolveSemanticType(target);
				if (targetId == null)
					targetId = context.resolveSemanticSymbol(target);
				for (moduleName in names) {
					if (!modules.exists(moduleName))
						continue;
					var dependencyState = modules.get(moduleName);
					for (owner => dependencies in dependencyState.semanticDependencies)
						for (dependency in dependencies) {
							var functionOwner:String = owner;
							var matches = dependency.targetId != null
								&& targetId != null ? dependency.targetId == targetId : SemanticDependencyCollector.sameDependencyTarget(dependency.target,
									target);
							if (matches) {
								invalidate(invalid, invalidationReasons, functionOwner, StructuralDependency, target, targetId, Std.string(dependency.kind));
								var matchedFunction = false;
								for (fn in functions)
									if (fn.name == functionOwner || StringTools.startsWith(fn.name, functionOwner + ".")) {
										invalidate(invalid, invalidationReasons, fn.name, StructuralDependency, target, targetId, Std.string(dependency.kind));
										matchedFunction = true;
									}
								if (matchedFunction)
									break;
							}
						}
				}
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
			for (field in classDecl.fields)
				if (!field.isStatic && field.initializer != null) {
					invalidate(invalid, invalidationReasons, constructorName, SourceRevision, owner);
					break;
				}
		}
		for (name in bodyChanged.keys())
			invalidate(invalid, invalidationReasons, name, BodyChanged, name);
		var reverseBodyDependencies:Map<String, Array<String>> = [];
		for (moduleName in names) {
			if (!modules.exists(moduleName))
				continue;
			for (owner => dependencies in modules.get(moduleName).semanticDependencies)
				for (dependency in dependencies)
					if (dependency.kind == compiler.modules.ModuleState.SemanticDependencyKind.Body && dependency.targetId != null) {
						var dependents = reverseBodyDependencies.get(dependency.targetId);
						if (dependents == null) {
							dependents = [];
							reverseBodyDependencies.set(dependency.targetId, dependents);
						}
						dependents.push(owner);
					}
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
		var genericCallers:Null<Map<String, Array<String>>> = null;
		var work:Array<String> = [for (name in changedSignatures.keys()) name], workCursor = 0;
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
				invalidate(invalid, invalidationReasons, changed, SignatureChanged, changed, context.resolveSemanticSymbol(changed));
			else if (!invalid.exists(changed))
				invalidate(invalid, invalidationReasons, changed, DependencySignature, changed);
			var changedId = context.resolveSemanticSymbol(changed);
			if (changedId != null && reverseBodyDependencies.exists(changedId))
				for (ownerName in reverseBodyDependencies.get(changedId)) {
					var owner = enclosingFunction(ownerName);
					if (!invalid.exists(owner)) {
						work.push(owner);
						invalidate(invalid, invalidationReasons, owner, DependencySignature, changed, changedId,
							Std.string(compiler.modules.ModuleState.SemanticDependencyKind.Body));
					}
				}
			if (changedSignatures.exists(changed) && reverseTypedCalls.exists(changed))
				for (caller in reverseTypedCalls.get(changed))
					if (!invalid.exists(caller)) {
						work.push(caller);
						invalidate(invalid, invalidationReasons, caller, DependencySignature, changed, changedId, "typed-call");
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
							invalidate(invalid, invalidationReasons, caller, DependencySignature, changed, changedId, "specialization-request");
						}
			}
			if (reverseCalls.exists(changed)) {
				var callers = reverseCalls.get(changed);
				for (callerName in callers) {
					var caller = enclosingFunction(callerName);
					if (!invalid.exists(caller)) {
						work.push(caller);
						invalidate(invalid, invalidationReasons, caller, DependencySignature, changed, changedId, "provisional-call");
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
			if (modules.exists(moduleName) && modules.get(moduleName).lastGoodRevision != modules.get(moduleName).revision)
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
		var entryPoint = context.executableEntryPoint(entryModule);
		var canonicalProgram:AstProgram = {
			packageName: null,
			imports: [],
			importAliases: [],
			aliases: typeAliases,
			enums: enums,
			enumAbstracts: enumAbstracts,
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
			generatedByModule: generatedByModule,
			invalidated: invalidated,
			selected: selected,
			invalidations: orderedInvalidations(invalidationReasons),
			entryPoint: entryPoint,
			aliasSetupMs: aliasesPreparedAt - startedAt,
			canonicalizationMs: canonicalizedAt - aliasesPreparedAt,
			contributionReuseMs: contributionReuseMs,
			contributionRebuildMs: contributionRebuildMs,
			invalidationMs: invalidatedAt - canonicalizedAt,
			allocatedBytes: #if haxeon hl.Gc.totalAllocated() - allocatedAtStart #elseif hl hl.Gc.stats().totalAllocated - allocatedAtStart #else 0.0 #end
		};
	}

	static function addSourceAlias(target:Map<String, String>, moduleAliases:Array<{sourceName:String, declarationName:String}>, moduleName:String,
			declarationName:String, packageName:Null<String>):Void {
		var sourceName = ModuleCanonicalizer.sourceDeclarationPath(moduleName, declarationName),
			canonicalName = ModuleCanonicalizer.qualifiedTypeName(packageName, declarationName);
		target.set(sourceName, canonicalName);
		moduleAliases.push({sourceName: sourceName, declarationName: canonicalName});
	}

	static function typedAtCurrentRevision(state:Null<ModuleState>, name:String):Bool
		return state != null
			&& state.typedFunctions.exists(name)
			&& state.typedSourceRevisions.get(name) == state.revision
			&& (state.irFunctions.exists(name) || state.pendingIrFunctions.exists(name));

	/** The functions whose lowered bodies call or refer to a specialization, by the generic function it was made from. */
	static function callersOfSpecializations(modules:Map<String, ModuleState>, names:Array<String>):Map<String, Array<String>> {
		var result:Map<String, Array<String>> = [];
		for (moduleName in names) {
			var state = modules.get(moduleName);
			if (state == null)
				continue;
			for (functionName => fn in state.irFunctions) {
				var caller = enclosingFunction(functionName),
					seen:Map<String, Bool> = [];
				for (block in fn.blocks)
					for (located in block.instructions) {
						var target = switch located.value {
							case Call(_, name, _), StaticClosure(_, name), InstanceClosure(_, name, _): name;
							default: null;
						};
						if (target == null || !StringTools.startsWith(target, "$generic:"))
							continue;
						var origin = enclosingFunction(target);
						if (seen.exists(origin))
							continue;
						seen.set(origin, true);
						var callers = result.get(origin);
						if (callers == null) {
							callers = [];
							result.set(origin, callers);
						}
						callers.push(caller);
					}
			}
		}
		return result;
	}

	/**
	 * A lambda is retyped with the function it is written in, so a dependency recorded on the lambda invalidates that function.
	 * Lambda names read `$lambda:<enclosing>:<id>`, and the enclosing name can itself be a generic specialization.
	 */
	static function enclosingFunction(name:String):String {
		while (StringTools.startsWith(name, "$lambda:")) {
			var end = name.lastIndexOf(":");
			if (end <= 8)
				break;
			name = name.substring(8, end);
		}
		if (StringTools.startsWith(name, "$generic:")) {
			var bracket = name.indexOf("[", 9);
			if (bracket > 0)
				name = name.substring(9, bracket);
		}
		return name;
	}

	static function addReverseCall(reverseCalls:Map<String, Array<String>>, callee:String, caller:String):Void {
		var callers = reverseCalls.get(callee);
		if (callers == null) {
			callers = [];
			reverseCalls.set(callee, callers);
		}
		callers.push(caller);
	}

	static function visibleTypeAliases(packageName:String, sourceTypeAliases:Map<String, String>, cache:Map<String, Map<String, String>>):Map<String, String> {
		if (cache.exists(packageName))
			return cache.get(packageName);
		var result:Map<String, String> = [],
			visiblePackage:Null<String> = packageName;
		while (visiblePackage != null) {
			var currentPackage:String = visiblePackage,
				packagePrefix = currentPackage.length == 0 ? "" : currentPackage + ".";
			for (sourceName => declarationName in sourceTypeAliases)
				if (StringTools.startsWith(sourceName, packagePrefix) && StringTools.startsWith(declarationName, packagePrefix)) {
					var relativeSourceName = sourceName.substring(packagePrefix.length, sourceName.length),
						simpleName = declarationName.substring(packagePrefix.length, declarationName.length);
					if (!result.exists(relativeSourceName))
						result.set(relativeSourceName, declarationName);
					if (simpleName.indexOf(".") < 0 && !result.exists(simpleName))
						result.set(simpleName, declarationName);
				}
			var separator = currentPackage.lastIndexOf(".");
			visiblePackage = separator < 0 ? null : currentPackage.substring(0, separator);
		}
		cache.set(packageName, result);
		return result;
	}

	static function invalidate(invalid:Map<String, Bool>, reasons:Map<String, Array<InvalidationReason>>, artifact:String, kind:InvalidationKind,
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
		return [for (name in names) {artifact: name, reasons: reasons.get(name)}];
	}

	/** A purity/no-return answer is recorded against the exact body that asked, which for a
	 * closure is its own `$lambda:origin:offset` name. Only the top-level function is ever
	 * independently retyped, so walk back through any lambda nesting to find it.
	 */
	static function purityDependencyOwner(name:String):String {
		var owner = name;
		while (StringTools.startsWith(owner, "$lambda:")) {
			var lastColon = owner.lastIndexOf(":");
			owner = owner.substring("$lambda:".length, lastColon);
		}
		return owner;
	}

	/** Prefer the last successfully resolved call graph; syntax calls bootstrap new declarations. */
	static function dependencyCalls(state:ModuleState, rollbackModules:Map<String, ModuleState>, owner:String, fallback:Array<String>):Array<String> {
		var previous = rollbackModules.exists(state.name) ? rollbackModules.get(state.name) : state,
			dependencies = previous.semanticDependencies.get(owner),
			resolved:Array<String> = [];
		if (dependencies != null)
			for (dependency in dependencies)
				if (dependency.kind == compiler.modules.ModuleState.SemanticDependencyKind.Body && dependency.targetId != null)
					resolved.push(dependency.target);
		return resolved.length == 0 ? fallback : resolved;
	}

	static function declaredDiscoveryPrefixes(classDecl:AstClass):Null<Array<String>> {
		for (metadata in classDecl.metadata)
			if (metadata.name == "discoverMethods") {
				if (metadata.arguments.length == 0)
					throw new CompileError(new Diagnostic("E1024", "@:discoverMethods requires at least one prefix", metadata.span));
				var prefixes:Array<String> = [];
				for (argument in metadata.arguments)
					switch argument {
						case AstExpression.StringLiteral(value, _):
							prefixes.push(value);
						default:
							throw new CompileError(new Diagnostic("E1024", "@:discoverMethods prefixes must be string literals", metadata.span));
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
				throw new CompileError(new Diagnostic("E1024", 'Discovered method "$className.${method.name}" must be a parameterless instance method',
					method.span));
			switch method.result {
				case AstType.VoidType, AstType.InferredType:
				default:
					throw new CompileError(new Diagnostic("E1024", 'Discovered method "$className.${method.name}" must return Void', method.span));
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
}
