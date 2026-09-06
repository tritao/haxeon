package compiler;

import compiler.Ast;
import compiler.Ast.AstExpression;
import compiler.Ast.AstFunction;
import compiler.Ast.AstStatement;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Lexer;
import compiler.Parser;
import compiler.Source.SourceFile;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.IrGenerator;
import compiler.types.FieldInference;
import compiler.types.SignatureInference;
import compiler.types.Typer;
import compiler.types.Typer.TyperPhaseMetrics;
import compiler.types.SemanticSignature;
import compiler.types.GenericSpecializationRegistry;
import compiler.types.SemanticProgram;
import compiler.types.TypedAst.TypedProgram;
import compiler.hl.HlCode;
import compiler.hl.incremental.HlModuleAssembler;
import compiler.hl.patch.HlPatchWriter;
import compiler.hl.persistence.HlRuntimeIdentity;
import compiler.hl.persistence.HlAssemblerStateCodec;
import haxe.io.Bytes;
import compiler.types.Type.CompilerType;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrObject;
import compiler.types.TypeRegistry;
import compiler.types.TypeRegistry.TypeCompatibility;
import compiler.service.CancellationToken;
import compiler.abi.RuntimeAbi;
import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;
import compiler.abi.PatchPlanner;
import compiler.abi.PatchPlanner.AbiChange;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.abi.NativeRegistry;
import compiler.abi.NativeRegistry.NativeDefinition;
import compiler.CompilerPublication.CompilerSnapshot;
import compiler.CompilerPublication.PublicationStatus;
import compiler.CompilerPublication.ReconnectDecision;
import compiler.CompilerPublication.ReconnectReason;
import compiler.modules.ModuleGraph;
import compiler.modules.ModulePath;
import compiler.modules.ModuleReachability;
import compiler.modules.ModuleState;
import compiler.modules.ModuleState.SemanticDependency;
import compiler.modules.ModuleState.SemanticDependencyKind;
import compiler.semantic.ModuleCanonicalizer;
import compiler.semantic.ModuleChangeAnalyzer;
import compiler.semantic.DependencyScanner;
import compiler.semantic.LambdaCollector;
import compiler.semantic.SemanticDependencyCollector;
import compiler.semantic.SemanticWorkspace;
import compiler.Compiler.CompileResult;

/** Executes the mutable frontend, IR, ABI-planning, and backend candidate phases. */
class CompilationPipeline {
	public static function compile(compiler:Compiler, entryModule:String, token:Null<CancellationToken>, rollbackModules:Map<String, ModuleState>,
			transactionStartedAt:Float, snapshotDoneAt:Float):CompileResult {
		var modules = compiler.modules,
			graph = compiler.graph,
			objectCache = compiler.objectCache;
		var moduleId = compiler.moduleId,
			assembler = compiler.assembler,
			publishedAbi = compiler.publishedAbi;
		var compiledOnce = compiler.compiledOnce,
			genericSpecializations = compiler.genericSpecializations;
		var startedAt = snapshotDoneAt;
		if (token != null)
			token.check();
		var bodyChanged:Map<String, Bool> = [],
			signatureChanged:Map<String, Bool> = [],
			structuralChanged:Map<String, Bool> = [];
		var reachability = new ModuleReachability(modules, entryModule);
		while (reachability.hasNext(token)) {
			var reachableState = reachability.next();
			if (reachableState.ast == null) {
				reachableState = compiler.writableState(reachableState.name, rollbackModules);
				compiler.parse(reachableState, entryModule, bodyChanged, signatureChanged, structuralChanged);
				compiler.addTypeDependencies(reachableState);
			}
			reachability.includeDependencies(reachableState);
		}
		var names = reachability.finish(token);
		graph.rebuild(modules);
		var initializationNames = graph.initializationOrder(modules, names),
			initializationClasses:Array<String> = [];
		for (name in initializationNames) {
			var state = modules.get(name);
			var ast = state.parsedAst();
			for (classDecl in ast.classes)
				initializationClasses.push(ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name));
		}

		var functions:Array<AstFunction> = [],
			programFunctions:Array<AstFunction> = [],
			typeAliases:Array<compiler.Ast.AstTypeAlias> = [],
			enums:Array<compiler.Ast.AstEnum> = [],
			enumAbstracts:Array<compiler.Ast.AstEnumAbstract> = [],
			abstracts:Array<compiler.Ast.AstAbstract> = [],
			interfaces:Array<compiler.Ast.AstInterface> = [],
			classes:Array<compiler.Ast.AstClass> = [],
			owners:Map<String, String> = [],
			generatedByModule:Map<String, Map<String, Bool>> = [],
			reverseCalls:Map<String, Array<String>> = [];
		var sourceTypeAliases:Map<String, String> = [];
		for (moduleName in names) {
			var moduleState = modules.get(moduleName),
				program = moduleState.parsedAst();
			for (declaration in program.aliases)
				sourceTypeAliases.set(ModuleCanonicalizer.sourceDeclarationPath(moduleName, declaration.name),
					ModuleCanonicalizer.qualifiedTypeName(program.packageName, declaration.name));
			for (declaration in program.enums)
				sourceTypeAliases.set(ModuleCanonicalizer.sourceDeclarationPath(moduleName, declaration.name),
					ModuleCanonicalizer.qualifiedTypeName(program.packageName, declaration.name));
			for (declaration in program.enumAbstracts)
				sourceTypeAliases.set(ModuleCanonicalizer.sourceDeclarationPath(moduleName, declaration.name),
					ModuleCanonicalizer.qualifiedTypeName(program.packageName, declaration.name));
			for (declaration in program.abstracts)
				sourceTypeAliases.set(ModuleCanonicalizer.sourceDeclarationPath(moduleName, declaration.name),
					ModuleCanonicalizer.qualifiedTypeName(program.packageName, declaration.name));
			for (declaration in program.interfaces)
				sourceTypeAliases.set(ModuleCanonicalizer.sourceDeclarationPath(moduleName, declaration.name),
					ModuleCanonicalizer.qualifiedTypeName(program.packageName, declaration.name));
			for (declaration in program.classes)
				sourceTypeAliases.set(ModuleCanonicalizer.sourceDeclarationPath(moduleName, declaration.name),
					ModuleCanonicalizer.qualifiedTypeName(program.packageName, declaration.name));
		}
		for (name in names) {
			if (token != null)
				token.check();
			var state = modules.get(name),
				ast = state.parsedAst(),
				locals:Map<String, Bool> = [],
				aliases = compiler.importAliases(ast.imports, ast.importAliases);
			for (sourceName => declarationName in sourceTypeAliases)
				aliases.set(sourceName, declarationName);
			for (importPath in ast.imports)
				if (modules.exists(importPath))
					for (sourceName => declarationName in sourceTypeAliases) {
						var qualifiedSourceName:String = sourceName;
						if (StringTools.startsWith(qualifiedSourceName, importPath + ".")) {
							var nestedStart = importPath.length + 1,
								nestedName = qualifiedSourceName.substring(nestedStart, qualifiedSourceName.length);
							if (nestedName.indexOf(".") < 0)
								aliases.set(nestedName, declarationName);
						}
					}
			var visiblePackage = ast.packageName;
			while (true) {
				var currentPackage:String;
				if (visiblePackage == null)
					break;
				else
					currentPackage = visiblePackage;
				var packagePrefix = currentPackage.length == 0 ? "" : currentPackage + ".";
				for (sourceName => declarationName in sourceTypeAliases) {
					var qualifiedSourceName:String = sourceName,
						qualifiedDeclarationName:String = declarationName;
					if (StringTools.startsWith(qualifiedSourceName, packagePrefix)
						&& StringTools.startsWith(qualifiedDeclarationName, packagePrefix)) {
						var relativeSourceName = qualifiedSourceName.substring(packagePrefix.length, qualifiedSourceName.length),
							simpleName = qualifiedDeclarationName.substring(packagePrefix.length, qualifiedDeclarationName.length);
						if (!aliases.exists(relativeSourceName))
							aliases.set(relativeSourceName, declarationName);
						if (simpleName.indexOf(".") < 0 && !aliases.exists(simpleName))
							aliases.set(simpleName, declarationName);
					}
				}
				var separator = -1,
					separatorCursor = currentPackage.length - 1;
				while (separatorCursor >= 0) {
					if (currentPackage.charCodeAt(separatorCursor) == 46) {
						separator = separatorCursor;
						break;
					}
					separatorCursor--;
				}
				visiblePackage = separator < 0 ? null : currentPackage.substring(0, separator);
			}
			ModuleCanonicalizer.addDeclaredTypeAliases(aliases, ast, ast.packageName);
			for (interfaceDecl in ast.interfaces)
				interfaces.push(ModuleCanonicalizer.canonicalInterface(interfaceDecl, aliases, ast.packageName));
			for (alias in ast.aliases)
				typeAliases.push(ModuleCanonicalizer.canonicalAlias(alias, aliases, ast.packageName));
			for (enumDecl in ast.enums)
				enums.push(ModuleCanonicalizer.canonicalEnum(enumDecl, aliases, ast.packageName));
			for (abstractDecl in ast.enumAbstracts)
				enumAbstracts.push(ModuleCanonicalizer.canonicalEnumAbstract(abstractDecl, aliases, ast.packageName, name, entryModule, locals));
			for (abstractDecl in ast.abstracts)
				abstracts.push(ModuleCanonicalizer.canonicalAbstract(abstractDecl, aliases, ast.packageName, name, entryModule, locals));
			for (fn in ast.functions)
				locals.set(fn.name, true);
			var aliasNames = [for (aliasName in aliases.keys()) aliasName];
			aliasNames.sort(Reflect.compare);
			var aliasKey = [for (aliasName in aliasNames) aliasName + "=" + aliases.get(aliasName)].join(";");
			var canonicalFunctions:Array<AstFunction>;
			if (state.canonicalRevision == state.revision && state.canonicalEntry == entryModule && state.canonicalAliasKey == aliasKey)
				canonicalFunctions = state.canonicalFunctions;
			else {
				state = compiler.writableState(name, rollbackModules);
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
				LambdaCollector.collect(canonical.statements, canonical.name, name, generatedByModule);
				for (callee in state.canonicalCalls.get(canonical.name)) {
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
				for (parameter in classDecl.typeParameters)
					classAliases.set(parameter, parameter);
				var classMethods:Array<AstFunction> = [];
				for (parsedMethod in classDecl.methods) {
					var method = SignatureInference.inferFieldBoundArguments(parsedMethod, classDecl);
					var canonical = ModuleCanonicalizer.canonicalFunction(method, name, entryModule, locals, className + "." + method.name, classAliases);
					functions.push(canonical);
					classMethods.push({
						name: method.name,
						isStatic: method.isStatic,
						typeParameters: method.typeParameters,
						arguments: canonical.arguments,
						result: canonical.result,
						span: method.span,
						statements: canonical.statements
					});
					owners.set(canonical.name, name);
					var calls:Map<String, Bool> = [];
					var aliases:Map<String, String> = [];
					for (statement in canonical.statements)
						SemanticDependencyCollector.scanCalls(statement, calls, aliases);
					LambdaCollector.collect(canonical.statements, canonical.name, name, generatedByModule);
					for (callee in calls.keys()) {
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
				classes.push({
					name: className,
					typeParameters: classDecl.typeParameters,
					isPrivate: classDecl.isPrivate,
					metadata: classDecl.metadata,
					base: ModuleCanonicalizer.resolveOptionalTypeName(classDecl.base, aliases),
					interfaces: [
						for (interfaceName in classDecl.interfaces)
							ModuleCanonicalizer.resolveTypeName(interfaceName, aliases)
					],
					fields: [
						for (field in classDecl.fields)
							{
								name: field.name,
								type: ModuleCanonicalizer.canonicalType(FieldInference.parsedType(field), classAliases, classDecl.typeParameters),
								initializer: ModuleCanonicalizer.canonicalOptionalExpression(field.initializer, name, entryModule, locals, aliases),
								readAccess: field.readAccess,
								writeAccess: field.writeAccess,
								isStatic: field.isStatic,
								isFinal: field.isFinal,
								span: field.span
							}
					],
					methods: classMethods,
					span: classDecl.span
				});
				owners.set(className + ".new", name);
			}
		}

		for (module => lambdaNames in generatedByModule)
			for (lambdaName in lambdaNames.keys())
				owners.set(lambdaName, module);
		var invalid:Map<String, Bool> = [];
		for (change in structuralChanged.keys()) {
			var changedDependency:String = change,
				separator = changedDependency.indexOf(":"),
				target = separator < 0 ? changedDependency : changedDependency.substring(separator + 1, changedDependency.length);
			for (moduleName in names) {
				var dependencyState = modules.get(moduleName);
				for (owner => dependencies in dependencyState.semanticDependencies)
					for (dependency in dependencies) {
						var functionOwner:String = owner;
						if (SemanticDependencyCollector.sameDependencyTarget(dependency.target, target)) {
							var matchedFunction = false;
							for (fn in functions)
								if (fn.name == functionOwner || StringTools.startsWith(fn.name, functionOwner + ".")) {
									invalid.set(fn.name, true);
									matchedFunction = true;
								}
							if (matchedFunction)
								break;
						}
					}
			}
		}
		for (name in bodyChanged.keys())
			invalid.set(name, true);
		var work:Array<String> = [for (name in signatureChanged.keys()) name], workCursor = 0;
		while (workCursor < work.length) {
			if (token != null)
				token.check();
			var changed = work[workCursor++];
			if (!invalid.exists(changed))
				invalid.set(changed, true);
			if (reverseCalls.exists(changed)) {
				var callers = reverseCalls.get(changed);
				for (caller in callers)
					if (!invalid.exists(caller))
						work.push(caller);
			}
		}
		var selected:Map<String, Bool> = [];
		for (name in invalid.keys())
			selected.set(name, true);
		var entryPoint = compiler.executableEntryPoint(entryModule);
		var frontendDoneAt = Sys.time() * 1000.0;
		var typedNew:TypedProgram, typerMetrics:TyperPhaseMetrics;
		try {
			if (token != null)
				token.check();
			var canonicalProgram:compiler.Ast.AstProgram = {
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
			var previousSemantic = compiler.cachedSemanticProgram;
			var canReuseSemantic = previousSemantic != null
				&& Compiler.mapIsEmpty(signatureChanged)
				&& Compiler.mapIsEmpty(structuralChanged)
				&& canonicalProgram.classes.length == 0
				&& canonicalProgram.abstracts.length == 0
				&& canonicalProgram.enumAbstracts.length == 0
				&& Compiler.explicitFunctionSignatures(canonicalProgram.functions);
			var semantic:SemanticProgram;
			if (canReuseSemantic && previousSemantic != null)
				semantic = previousSemantic.replaceTopLevelBodies(canonicalProgram, selected);
			else
				semantic = SemanticProgram.analyze(canonicalProgram);
			compiler.cachedSemanticProgram = semantic;
			var typedResult = Typer.typeAnalyzedMeasured(semantic, selected, compiler.nativeSignatures(), entryPoint, genericSpecializations);
			typedNew = typedResult.program;
			typerMetrics = typedResult.metrics;
		} catch (error:CompileError) {
			for (name in names) {
				var state = modules.get(name);
				if (state.source.path == error.diagnostic.span.file.path)
					compiler.writableState(name, rollbackModules).diagnostics.push(error.diagnostic);
			}
			throw error;
		}
		var retyped = [], regenerated = [];
		for (object in IrGenerator.objectsFrom(typedNew))
			objectCache.set(object.name, object);
		var touchedModules:Map<String, Bool> = [];
		for (fn in typedNew.functions) {
			if (token != null)
				token.check();
			var module:String;
			if (owners.exists(fn.name))
				module = owners.get(fn.name);
			else {
				var genericOrigin = fn.genericOrigin;
				if (genericOrigin == null || !owners.exists(genericOrigin))
					throw 'No source module owns typed function "${fn.name}"';
				module = owners.get(genericOrigin);
				owners.set(fn.name, module);
				var generatedNames:Map<String, Bool>;
				if (generatedByModule.exists(module))
					generatedNames = generatedByModule.get(module);
				else {
					generatedNames = [];
					generatedByModule.set(module, generatedNames);
				}
				generatedNames.set(fn.name, true);
			}
			var state = compiler.writableState(module, rollbackModules);
			state.typedFunctions.set(fn.name, fn);
			state.typedSourceRevisions.set(fn.name, state.revision);
			retyped.push(fn.name);
			touchedModules.set(module, true);
			state.irFunctions.set(fn.name, IrGenerator.generateFunction(fn));
			state.irSourceRevisions.set(fn.name, state.revision);
			regenerated.push(fn.name);
			var version = state.irVersions.exists(fn.name) ? state.irVersions.get(fn.name) + 1 : 1;
			state.irVersions.set(fn.name, version);
		}
		for (module in touchedModules.keys())
			modules.get(module).typeVersion++;
		for (name in names) {
			if (token != null)
				token.check();
			var state = modules.get(name),
				ast = state.parsedAst(),
				valid:Map<String, Bool> = [];
			for (fn in functions)
				if (owners.exists(fn.name) && owners.get(fn.name) == name)
					valid.set(fn.name, true);
			if (generatedByModule.exists(name)) {
				var lambdaNames = generatedByModule.get(name);
				for (lambdaName in lambdaNames.keys())
					valid.set(lambdaName, true);
			}
			for (classDecl in ast.classes) {
				var className = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name),
					hasInstanceInitializer = false,
					hasConstructor = false;
				for (field in classDecl.fields)
					if (!field.isStatic && field.initializer != null)
						hasInstanceInitializer = true;
				for (method in classDecl.methods)
					if (method.name == "new")
						hasConstructor = true;
				if (hasInstanceInitializer || hasConstructor)
					valid.set(className + ".new", true);
			}
			var removed = [for (cached in state.typedFunctions.keys()) if (!valid.exists(cached)) cached];
			if (removed.length > 0) {
				state = compiler.writableState(name, rollbackModules);
				for (cached in removed) {
					state.typedFunctions.remove(cached);
					state.typedSourceRevisions.remove(cached);
					state.irFunctions.remove(cached);
					state.irSourceRevisions.remove(cached);
					state.irVersions.remove(cached);
				}
			}
		}
		retyped.sort(Reflect.compare);
		regenerated.sort(Reflect.compare);
		var typingLoweringDoneAt = Sys.time() * 1000.0;
		var cachedNames:Array<String> = [];
		for (moduleName in names) {
			var state = modules.get(moduleName);
			for (functionName in state.irFunctions.keys())
				cachedNames.push(functionName);
		}
		cachedNames.sort(Reflect.compare);
		var cached = [
			for (functionName in cachedNames)
				modules.get(owners.get(functionName)).irFunctions.get(functionName)
		];
		if (token != null)
			token.check();
		var objectNames = [for (name in objectCache.keys()) name];
		objectNames.sort(Reflect.compare);
		var ir = IrGenerator.assemble(cached, compiler.irNatives(), [for (name in objectNames) objectCache.get(name)], IrGenerator.interfacesFrom(typedNew),
			IrGenerator.enumsFrom(typedNew), IrGenerator.staticFieldsFrom(typedNew), IrGenerator.staticInitializerFrom(typedNew, initializationClasses),
			entryPoint);
		var irAssemblyDoneAt = Sys.time() * 1000.0;
		var nextAbi = RuntimeAbi.describe(ir),
			decision = PatchPlanner.plan(publishedAbi, nextAbi),
			reloadReasons:Array<AbiChange> = switch decision {
				case Patch: [];
				case ReloadDomain(reasons): reasons;
				case Reject(diagnostics): throw diagnostics.join("; ");
			};
		reloadReasons.sort(function(a, b) return Reflect.compare(Std.string(a), Std.string(b)));
		if (reloadReasons.length > 0)
			decision = ReloadDomain(reloadReasons);
		var abiPlanningDoneAt = Sys.time() * 1000.0;
		var candidateAssembler = compiledOnce
			&& PatchPlanner.requiresFreshLayout(decision) ? new HlModuleAssembler(Compiler.copyIndices(assembler.cache.stableIds)) : assembler.copy();
		var assembly = candidateAssembler.assemble(ir, compiler.rehydratedChanges(regenerated, ir), decision);
		var backendAssemblyDoneAt = Sys.time() * 1000.0;
		if (token != null)
			token.check();
		var patchBytes = reloadReasons.length > 0
			|| assembly.changedFunctions.length == 0 ? null : HlPatchWriter.encode(assembly.module, moduleId, assembly.changedSlots,
				compiler.stableIdsBySlot(candidateAssembler, assembly.functionIndices), assembly.revision - 1, assembly.revision, assembly.baseInts,
				assembly.baseFloats, assembly.baseStrings, assembly.baseTypes);
		var patchEncodingDoneAt = Sys.time() * 1000.0;
		compiler.lastTypedProgram = typedNew;
		compiler.publishedAbi = nextAbi;
		compiler.assembler = candidateAssembler;
		compiler.rehydrationBaseline = null;
		for (name in names) {
			var state = modules.get(name);
			if (state.lastGoodRevision != state.revision) {
				state = compiler.writableState(name, rollbackModules);
				state.lastGoodTokens = state.tokens;
				state.lastGoodAst = state.ast;
				state.lastGoodSemanticModel = state.semanticModel;
				state.lastGoodSource = state.source;
				state.lastGoodRevision = state.revision;
			}
		}
		compiler.compiledOnce = true;
		var finishedAt = Sys.time() * 1000.0;
		return {
			ir: ir,
			module: assembly.module,
			retyped: retyped,
			regenerated: regenerated,
			changedFunctions: assembly.changedFunctions,
			requiresReload: assembly.requiresReload,
			reloadReasons: reloadReasons,
			functionIndices: Compiler.copyIndices(assembly.functionIndices),
			functionIds: Compiler.copyIndices(candidateAssembler.cache.stableIds),
			runtimeIdentity: HlRuntimeIdentity.encode(moduleId, assembly.revision, assembly.functionIndices, candidateAssembler.cache.stableIds),
			revision: assembly.revision,
			patchBytes: patchBytes,
			metrics: {
				elapsedMs: finishedAt - transactionStartedAt,
				transactionSnapshotMs: snapshotDoneAt - transactionStartedAt,
				frontendMs: frontendDoneAt - startedAt,
				typingLoweringMs: typingLoweringDoneAt - frontendDoneAt,
				typerSetupMs: typerMetrics.setupMs,
				typerNoReturnMs: typerMetrics.noReturnMs,
				typerMetadataMs: typerMetrics.metadataMs,
				typerBodiesMs: typerMetrics.bodiesMs,
				typerAssemblyMs: typerMetrics.assemblyMs,
				irAssemblyMs: irAssemblyDoneAt - typingLoweringDoneAt,
				abiPlanningMs: abiPlanningDoneAt - irAssemblyDoneAt,
				backendAssemblyMs: backendAssemblyDoneAt - abiPlanningDoneAt,
				patchEncodingMs: patchEncodingDoneAt - backendAssemblyDoneAt,
				finalizeMs: finishedAt - patchEncodingDoneAt,
				modules: names.length,
				retypedFunctions: retyped.length,
				regeneratedFunctions: regenerated.length,
				changedFunctions: assembly.changedFunctions.length,
				moduleFunctions: assembly.module.functions.length,
				moduleNatives: assembly.module.natives.length,
				patchBytes: patchBytes == null ? 0 : patchBytes.length
			}
		};
	}
}
