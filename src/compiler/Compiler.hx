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

/** Public alias for a host-native declaration accepted by the compiler. */
typedef NativeFunction = NativeDefinition;

/** Artifacts, invalidation details, and publication metadata from a successful build. */
typedef CompileResult = {
	final ir:IrProgram;
	final module:HlCode;
	final retyped:Array<String>;
	final regenerated:Array<String>;
	final changedFunctions:Array<Int>;
	final requiresReload:Bool;
	final reloadReasons:Array<AbiChange>;
	final functionIndices:Map<String, Int>;
	final functionIds:Map<String, Int>;
	final runtimeIdentity:Bytes;
	final revision:Int;
	final patchBytes:Null<Bytes>;
	final metrics:CompileMetrics;
}

/** Work and output-size counters measured for one compilation. */
typedef CompileMetrics = {
	final elapsedMs:Float;
	final transactionSnapshotMs:Float;
	final frontendMs:Float;
	final typingLoweringMs:Float;
	final typerSetupMs:Float;
	final typerNoReturnMs:Float;
	final typerMetadataMs:Float;
	final typerBodiesMs:Float;
	final typerAssemblyMs:Float;
	final irAssemblyMs:Float;
	final abiPlanningMs:Float;
	final backendAssemblyMs:Float;
	final patchEncodingMs:Float;
	final finalizeMs:Float;
	final modules:Int;
	final retypedFunctions:Int;
	final regeneratedFunctions:Int;
	final changedFunctions:Int;
	final moduleFunctions:Int;
	final moduleNatives:Int;
	final patchBytes:Int;
}

/** Non-mutating validation outcome for a prospective source update. */
typedef ValidationResult = {
	final valid:Bool;
	final diagnostic:Null<Diagnostic>;
}

/**
 * Persistent incremental compiler and owner of all module and backend state.
 * Compilation is transactional: failed edits do not replace published artifacts.
 */
@:allow(compiler.CompilationTransaction)
class Compiler {
	final genericSpecializations = new GenericSpecializationRegistry();

	public final modules:Map<String, ModuleState> = [];
	public final semanticWorkspace:SemanticWorkspace;

	/** Last successfully assembled typed program; failed edits never replace it. */
	public var lastTypedProgram:Null<TypedProgram> = null;

	final graph = new ModuleGraph();
	var assembler:HlModuleAssembler;
	final moduleId:Bytes;

	public var types(default, null):TypeRegistry;

	final natives:NativeRegistry;
	var objectCache:Map<String, IrObject> = [];
	var publishedAbi:Null<RuntimeAbiDescriptor>;
	var compiledOnce = false;
	final publication = new CompilerPublication();
	var rehydrationBaseline:Null<Map<String, Bytes>>;
	var sourceGeneration = 0;
	var cachedCompileGeneration = -1;
	var cachedCompileEntry:Null<String>;
	var cachedCompileResult:Null<CompileResult>;
	var cachedSemanticProgram:Null<SemanticProgram>;

	public function new(?identityState:Bytes, ?nativeConfiguration:Array<NativeFunction>) {
		semanticWorkspace = new SemanticWorkspace(modules);
		natives = new NativeRegistry(nativeConfiguration);
		if (identityState == null) {
			moduleId = HlRuntimeIdentity.createModuleId();
			assembler = new HlModuleAssembler();
			types = new TypeRegistry();
		} else {
			var identity = HlRuntimeIdentity.decodePersistent(identityState);
			moduleId = identity.moduleId;
			var assemblerState = identity.assemblerState;
			assembler = assemblerState == null ? new HlModuleAssembler(identity.stableIds) : HlAssemblerStateCodec.decode(assemblerState);
			for (name => id in identity.stableIds)
				if (assembler.cache.stableIds.get(name) != id)
					throw "Assembler stable identities do not match compiler state";
			for (name => id in assembler.cache.stableIds)
				if (identity.stableIds.get(name) != id)
					throw "Assembler stable identities do not match compiler state";
			types = new TypeRegistry(identity.typeState);
			publishedAbi = identity.publishedAbi;
			if (identity.publicationTracking)
				publication.enable(identity.acknowledgedRevision, identity.acknowledgedAbi, identity.assemblerState != null);
			if (identity.assemblerState != null) {
				compiledOnce = true;
				beginRehydration(assembler);
			}
		}
	}

	public function exportIdentityState():Bytes {
		var state = publication.persistence();
		var backend = state.tracking && state.revision > 0 ? HlAssemblerStateCodec.encode(assembler) : null;
		return HlRuntimeIdentity.encodePersistent(moduleId, assembler.cache.stableIds, types.exportState(), publishedAbi, state.tracking, state.revision,
			state.abi, backend);
	}

	public function enablePublicationTracking():Void {
		publication.enable();
	}

	public function publicationStatus():PublicationStatus
		return publication.status();

	public function reconcileRuntime(runtimeModuleId:Bytes, runtimeRevision:Int):ReconnectDecision {
		if (runtimeModuleId.length != moduleId.length || runtimeModuleId.compare(moduleId) != 0)
			return ReloadDomain(ModuleIdentityMismatch);
		return publication.reconcile(runtimeRevision);
	}

	function beginRehydration(restored:HlModuleAssembler):Void {
		var baseline:Map<String, Bytes> = [];
		rehydrationBaseline = baseline;
		for (name => fn in restored.cache.functions)
			baseline.set(name, compiler.ir.codec.IrFunctionStateCodec.encode(fn));
	}

	public function acknowledgePublication(revision:Int):Void
		publication.acknowledge(revision);

	public function rejectPublication(revision:Int):Void {
		var candidate = publication.reject(revision);
		restore(candidate.snapshot);
		assembler = candidate.assembler;
	}

	public function registerNative(name:String, library:String, symbol:String, arguments:Array<CompilerType>, result:CompilerType):Void {
		if (compiledOnce)
			throw "Native registrations are frozen after the first compilation";
		natives.registerNative(name, library, symbol, arguments, result);
	}

	public function nativeConfiguration():Array<NativeFunction> {
		return natives.configuration();
	}

	public function compact(entryModule:String):CompileResult {
		var result = new CompilationTransaction(this, entryModule, null, new HlModuleAssembler(assembler.cache.stableIds)).run();
		rememberCompile(entryModule, result);
		return result;
	}

	public function update(path:String, source:String):ModuleState {
		var name = ModulePath.fromFile(path),
			file = new SourceFile(path, source);
		var state:ModuleState;
		if (modules.exists(name)) {
			state = modules.get(name);
			state.update(file);
		} else {
			state = new ModuleState(name, file);
			modules.set(name, state);
		}
		sourceGeneration++;
		return state;
	}

	/**
		Validate an unsaved edit without mutating this compiler's live snapshot.
		The candidate is rebuilt from the persistent identity state and current
		sources; callers can then decide whether to commit the edit normally.
	 */
	public function validate(path:String, source:String, entryModule:String, ?token:CancellationToken):ValidationResult {
		var candidate = fork(), moduleName = ModulePath.fromFile(path);
		for (name in [for (name in candidate.modules.keys()) name])
			if (name == moduleName)
				candidate.modules.remove(name);
		candidate.update(path, source);
		try {
			candidate.compile(entryModule, token);
			return {valid: true, diagnostic: null};
		} catch (error:CompileError)
			return {valid: false, diagnostic: error.diagnostic};
	}

	/** Compile a temporary Int-returning expression without changing this compiler. */
	public function compileExpressionInt(expression:String):CompileResult {
		var candidate = fork();
		candidate.update("__repl__.hx", 'function __repl_value():Int { return $expression; } function main():Int { return __repl_value(); }');
		return candidate.compile("__repl__");
	}

	function fork():Compiler {
		var candidate = new Compiler(exportIdentityState(), nativeConfiguration());
		var moduleNames = [for (name in modules.keys()) name];
		moduleNames.sort(Reflect.compare);
		for (name in moduleNames) {
			var state = modules.get(name);
			candidate.update(state.source.path, state.source.text);
		}
		return candidate;
	}

	public function compile(entryModule:String, ?token:CancellationToken):CompileResult {
		var cached = cachedCompileResult, cachedEntry = cachedCompileEntry;
		if (!publication.status().tracking
			&& cached != null
			&& cachedCompileGeneration == sourceGeneration
			&& cachedEntry != null
			&& cachedEntry == entryModule) {
			if (token != null)
				token.check();
			return {
				ir: cached.ir,
				module: cached.module,
				retyped: [],
				regenerated: [],
				changedFunctions: [],
				requiresReload: false,
				reloadReasons: [],
				functionIndices: cached.functionIndices,
				functionIds: cached.functionIds,
				runtimeIdentity: cached.runtimeIdentity,
				revision: cached.revision,
				patchBytes: null,
				metrics: {
					elapsedMs: 0.0,
					transactionSnapshotMs: 0.0,
					frontendMs: 0.0,
					typingLoweringMs: 0.0,
					typerSetupMs: 0.0,
					typerNoReturnMs: 0.0,
					typerMetadataMs: 0.0,
					typerBodiesMs: 0.0,
					typerAssemblyMs: 0.0,
					irAssemblyMs: 0.0,
					abiPlanningMs: 0.0,
					backendAssemblyMs: 0.0,
					patchEncodingMs: 0.0,
					finalizeMs: 0.0,
					modules: cached.metrics.modules,
					retypedFunctions: 0,
					regeneratedFunctions: 0,
					changedFunctions: 0,
					moduleFunctions: cached.metrics.moduleFunctions,
					moduleNatives: cached.metrics.moduleNatives,
					patchBytes: 0
				}
			};
		}
		var result = new CompilationTransaction(this, entryModule, token, null).run();
		rememberCompile(entryModule, result);
		return result;
	}

	function rememberCompile(entryModule:String, result:CompileResult):Void {
		cachedCompileGeneration = sourceGeneration;
		cachedCompileEntry = entryModule;
		cachedCompileResult = result;
	}

	function compileCandidate(entryModule:String, token:Null<CancellationToken>, rollbackModules:Map<String, ModuleState>, transactionStartedAt:Float,
			snapshotDoneAt:Float):CompileResult {
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
				reachableState = writableState(reachableState.name, rollbackModules);
				parse(reachableState, entryModule, bodyChanged, signatureChanged, structuralChanged);
				addTypeDependencies(reachableState);
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
				aliases = importAliases(ast.imports, ast.importAliases);
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
				state = writableState(name, rollbackModules);
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
		var entryPoint = executableEntryPoint(entryModule);
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
			var previousSemantic = cachedSemanticProgram;
			var canReuseSemantic = previousSemantic != null
				&& mapIsEmpty(signatureChanged)
				&& mapIsEmpty(structuralChanged)
				&& canonicalProgram.classes.length == 0
				&& canonicalProgram.abstracts.length == 0
				&& canonicalProgram.enumAbstracts.length == 0
				&& explicitFunctionSignatures(canonicalProgram.functions);
			var semantic:SemanticProgram;
			if (canReuseSemantic && previousSemantic != null)
				semantic = previousSemantic.replaceTopLevelBodies(canonicalProgram, selected);
			else
				semantic = SemanticProgram.analyze(canonicalProgram);
			cachedSemanticProgram = semantic;
			var typedResult = Typer.typeAnalyzedMeasured(semantic, selected, nativeSignatures(), entryPoint, genericSpecializations);
			typedNew = typedResult.program;
			typerMetrics = typedResult.metrics;
		} catch (error:CompileError) {
			for (name in names) {
				var state = modules.get(name);
				if (state.source.path == error.diagnostic.span.file.path)
					writableState(name, rollbackModules).diagnostics.push(error.diagnostic);
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
			var state = writableState(module, rollbackModules);
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
				state = writableState(name, rollbackModules);
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
		var ir = IrGenerator.assemble(cached, irNatives(), [for (name in objectNames) objectCache.get(name)], IrGenerator.interfacesFrom(typedNew),
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
			&& PatchPlanner.requiresFreshLayout(decision) ? new HlModuleAssembler(copyIndices(assembler.cache.stableIds)) : assembler.copy();
		var assembly = candidateAssembler.assemble(ir, rehydratedChanges(regenerated, ir), decision);
		var backendAssemblyDoneAt = Sys.time() * 1000.0;
		if (token != null)
			token.check();
		var patchBytes = reloadReasons.length > 0
			|| assembly.changedFunctions.length == 0 ? null : HlPatchWriter.encode(assembly.module, moduleId, assembly.changedSlots,
				stableIdsBySlot(candidateAssembler, assembly.functionIndices), assembly.revision - 1, assembly.revision, assembly.baseInts,
				assembly.baseFloats, assembly.baseStrings, assembly.baseTypes);
		var patchEncodingDoneAt = Sys.time() * 1000.0;
		lastTypedProgram = typedNew;
		publishedAbi = nextAbi;
		assembler = candidateAssembler;
		rehydrationBaseline = null;
		for (name in names) {
			var state = modules.get(name);
			if (state.lastGoodRevision != state.revision) {
				state = writableState(name, rollbackModules);
				state.lastGoodTokens = state.tokens;
				state.lastGoodAst = state.ast;
				state.lastGoodSemanticModel = state.semanticModel;
				state.lastGoodSource = state.source;
				state.lastGoodRevision = state.revision;
			}
		}
		compiledOnce = true;
		var finishedAt = Sys.time() * 1000.0;
		return {
			ir: ir,
			module: assembly.module,
			retyped: retyped,
			regenerated: regenerated,
			changedFunctions: assembly.changedFunctions,
			requiresReload: assembly.requiresReload,
			reloadReasons: reloadReasons,
			functionIndices: copyIndices(assembly.functionIndices),
			functionIds: copyIndices(assembler.cache.stableIds),
			runtimeIdentity: HlRuntimeIdentity.encode(moduleId, assembly.revision, assembly.functionIndices, assembler.cache.stableIds),
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

	function executableEntryPoint(entryModule:String):String {
		var ast = modules.get(entryModule).parsedAst();
		for (fn in ast.functions)
			if (fn.name == "main")
				return "main";
		for (classDecl in ast.classes)
			for (method in classDecl.methods)
				if (method.name == "main" && method.isStatic)
					return ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name) + ".main";
		return "main";
	}

	function addTypeDependencies(state:ModuleState):Void {
		var dependencies:Map<String, Bool> = [];
		for (name in state.dependencies)
			dependencies.set(name, true);
		var ast = state.parsedAst();
		for (alias in ast.aliases)
			addModuleTypeDependency(alias.type, state, dependencies);
		for (enumDecl in ast.enums)
			for (caseDecl in enumDecl.cases)
				for (parameter in caseDecl.params)
					addModuleTypeDependency(parameter.type, state, dependencies);
		for (interfaceDecl in ast.interfaces)
			for (method in interfaceDecl.methods)
				addFunctionTypeDependencies(method, state, dependencies);
		for (classDecl in ast.classes) {
			var base = classDecl.base;
			if (base != null) {
				var owner = sourceModuleForType(base, ast.packageName);
				if (owner != null && owner != state.name)
					dependencies.set(owner, true);
			}
			for (field in classDecl.fields)
				addModuleTypeDependency(FieldInference.parsedType(field), state, dependencies);
			for (method in classDecl.methods)
				addFunctionTypeDependencies(method, state, dependencies);
		}
		for (fn in ast.functions)
			addFunctionTypeDependencies(fn, state, dependencies);
		state.dependencies = [for (name in dependencies.keys()) name];
		state.dependencies.sort(Reflect.compare);
	}

	function addFunctionTypeDependencies(fn:AstFunction, state:ModuleState, dependencies:Map<String, Bool>):Void {
		for (argument in fn.arguments)
			addModuleTypeDependency(argument.type, state, dependencies);
		addModuleTypeDependency(fn.result, state, dependencies);
	}

	function addModuleTypeDependency(type:compiler.Ast.AstType, state:ModuleState, dependencies:Map<String, Bool>):Void
		switch type {
			case NamedType(name):
				var ast = state.parsedAst(),
					owner = sourceModuleForType(name, ast.packageName);
				if (owner != null && owner != state.name)
					dependencies.set(owner, true);
			case ArrayType(element), NullableType(element):
				addModuleTypeDependency(element, state, dependencies);
			case MapType(key, value):
				addModuleTypeDependency(key, state, dependencies);
				addModuleTypeDependency(value, state, dependencies);
			case FunctionType(arguments, result):
				for (argument in arguments)
					addModuleTypeDependency(argument, state, dependencies);
				addModuleTypeDependency(result, state, dependencies);
			case AnonymousType(fields):
				for (field in fields)
					addModuleTypeDependency(field.type, state, dependencies);
			default:
		}

	function sourceModuleForType(typeName:String, packageName:Null<String>):Null<String> {
		var qualified = typeName.indexOf(".") < 0 && packageName != null ? packageName + "." + typeName : typeName,
			module = sourceModuleForDependency(qualified);
		if (module != null)
			return module;
		for (name => state in modules) {
			var ast = state.ast;
			if (ast == null)
				continue;
			var declaredPackage = ast.packageName,
				prefix = declaredPackage == null ? "" : declaredPackage + ".";
			for (declaration in ast.aliases)
				if (prefix + declaration.name == qualified)
					return name;
			for (declaration in ast.enums)
				if (prefix + declaration.name == qualified)
					return name;
			for (declaration in ast.interfaces)
				if (prefix + declaration.name == qualified)
					return name;
			for (declaration in ast.classes)
				if (prefix + declaration.name == qualified)
					return name;
		}
		return null;
	}

	function rehydratedChanges(regenerated:Array<String>, program:IrProgram):Array<String> {
		var baseline = rehydrationBaseline;
		if (baseline == null)
			return regenerated;
		var current:Map<String, compiler.ir.IrFunction> = [], changed = [];
		for (fn in program.functions)
			current.set(fn.name, fn);
		for (name in regenerated) {
			if (!baseline.exists(name) || !current.exists(name)) {
				changed.push(name);
				continue;
			}
			var old = baseline.get(name), next = current.get(name);
			if (old.compare(compiler.ir.codec.IrFunctionStateCodec.encode(next)) != 0)
				changed.push(name);
		}
		return changed;
	}

	function snapshot():CompilerSnapshot {
		var moduleCopies:Map<String, ModuleState> = [],
			objectCopies:Map<String, IrObject> = [];
		for (name => state in modules)
			moduleCopies.set(name, state);
		for (name => object in objectCache)
			objectCopies.set(name, object);
		return {
			modules: moduleCopies,
			types: types.copy(),
			objectCache: objectCopies,
			lastTypedProgram: lastTypedProgram,
			publishedAbi: publishedAbi,
			compiledOnce: compiledOnce,
			rehydrationBaseline: rehydrationBaseline,
			semanticProgram: cachedSemanticProgram
		};
	}

	function writableState(name:String, rollbackModules:Map<String, ModuleState>):ModuleState {
		var state = modules.get(name);
		if (rollbackModules.get(name) == state) {
			state = state.copy();
			modules.set(name, state);
		}
		return state;
	}

	function restore(snapshot:CompilerSnapshot):Void {
		for (name in [for (name in modules.keys()) name])
			modules.remove(name);
		for (name => state in snapshot.modules)
			modules.set(name, state);
		types = snapshot.types;
		objectCache = snapshot.objectCache;
		lastTypedProgram = snapshot.lastTypedProgram;
		publishedAbi = snapshot.publishedAbi;
		compiledOnce = snapshot.compiledOnce;
		rehydrationBaseline = snapshot.rehydrationBaseline;
		cachedSemanticProgram = snapshot.semanticProgram;
	}

	static function explicitFunctionSignatures(functions:Array<AstFunction>):Bool {
		for (fn in functions) {
			if (fn.result == InferredType)
				return false;
			for (argument in fn.arguments)
				if (argument.type == InferredType)
					return false;
		}
		return true;
	}

	function nativeSignatures():Map<String, {arguments:Array<CompilerType>, result:CompilerType}> {
		return natives.signatures();
	}

	function irNatives():Array<IrNative>
		return natives.irNatives();

	function stableIdsBySlot(sourceAssembler:HlModuleAssembler, layout:Map<String, Int>):Map<Int, Int> {
		var result:Map<Int, Int> = [];
		for (name => id in sourceAssembler.cache.stableIds)
			if (layout.exists(name))
				result.set(layout.get(name), id);
		return result;
	}

	function parse(state:ModuleState, entry:String, bodyChanged:Map<String, Bool>, signatureChanged:Map<String, Bool>,
			structuralChanged:Map<String, Bool>):Void {
		if (state.ast != null)
			return;
		try {
			state.tokens = new Lexer(state.source).tokenize();
			state.ast = new Parser(state.tokens).parseProgram();
			state.semanticModel = new compiler.types.SemanticModel(state.parsedAst(), state.source, state.revision);
			state.parseVersion++;
		} catch (error:CompileError) {
			state.diagnostics.push(error.diagnostic);
			throw error;
		}
		var ast = state.parsedAst(), dependencies:Map<String, Bool> = [];
		for (dependency in ast.imports)
			dependencies.set(dependency, true);
		for (fn in ast.functions)
			for (statement in fn.statements)
				DependencyScanner.scanStatement(statement, dependencies);
		for (classDecl in ast.classes)
			for (field in classDecl.fields) {
				var initializer = field.initializer;
				if (initializer != null)
					DependencyScanner.scanExpression(initializer, dependencies);
			}
		for (classDecl in ast.classes)
			for (method in classDecl.methods)
				for (statement in method.statements)
					DependencyScanner.scanStatement(statement, dependencies);
		for (abstractDecl in ast.abstracts)
			for (method in abstractDecl.methods)
				for (statement in method.statements)
					DependencyScanner.scanStatement(statement, dependencies);
		for (abstractDecl in ast.enumAbstracts)
			for (value in abstractDecl.values)
				DependencyScanner.scanExpression(value.value, dependencies);
		for (classDecl in ast.classes) {
			dependencies.remove(classDecl.name);
			for (field in classDecl.fields)
				dependencies.remove(field.name);
		}
		for (enumDecl in ast.enums)
			dependencies.remove(enumDecl.name);
		for (abstractDecl in ast.enumAbstracts)
			dependencies.remove(abstractDecl.name);
		for (abstractDecl in ast.abstracts)
			dependencies.remove(abstractDecl.name);
		for (importPath in ast.imports) {
			var alias = lastPathSegment(importPath);
			if (alias != importPath)
				dependencies.remove(alias);
		}
		for (alias in ast.importAliases.keys())
			dependencies.remove(alias);
		// Dotted native names such as Sys.time look like module-qualified calls
		// to the dependency scanner.  Registered natives own those prefixes and
		// must not require a source module with the same name.
		for (dependency in [for (dependency in dependencies.keys()) dependency])
			if (nativePrefixExists(dependency))
				dependencies.remove(dependency);
		var packageName = ast.packageName;
		for (dependency in [for (dependency in dependencies.keys()) dependency]) {
			var sourceModule = sourceModuleForDependency(dependency);
			if (sourceModule == null && isPlatformDependency(dependency)) {
				dependencies.remove(dependency);
				continue;
			}
			if (dependency.indexOf(".") < 0 && packageName != null) {
				var packageCandidate = packageName + "." + dependency;
				if (modules.exists(packageCandidate)) {
					dependencies.remove(dependency);
					dependencies.set(packageCandidate, true);
					continue;
				}
			}
			if (sourceModule == null && dependency.indexOf(".") < 0 && hasSourceModuleImport(ast.imports)) {
				dependencies.remove(dependency);
				continue;
			}
			if (sourceModule == null && dependency.indexOf(".") < 0 && packageName != null) {
				var packageCandidate = packageName + "." + dependency;
				dependencies.remove(dependency);
				dependencies.set(packageCandidate, true);
				continue;
			}
			if (sourceModule != null && sourceModule != dependency) {
				dependencies.remove(dependency);
				dependencies.set(sourceModule, true);
			}
		}
		state.dependencies = [for (name in dependencies.keys()) name];
		state.dependencies.sort(Reflect.compare);
		var typeAliases = importAliases(ast.imports, ast.importAliases);
		ModuleCanonicalizer.addDeclaredTypeAliases(typeAliases, ast, ast.packageName);
		state.semanticDependencies = SemanticDependencyCollector.collectSemanticDependencies(state, entry, typeAliases);
		var changes = ModuleChangeAnalyzer.analyze(state, entry, typeAliases, types, compiledOnce);
		mergeChanges(bodyChanged, changes.bodyChanged);
		mergeChanges(signatureChanged, changes.signatureChanged);
		mergeChanges(structuralChanged, changes.structuralChanged);
		state.signatureFingerprints = changes.signatureFingerprints;
		state.bodyFingerprints = changes.bodyFingerprints;
		state.interfaceFingerprints = changes.interfaceFingerprints;
		state.aliasFingerprints = changes.aliasFingerprints;
		state.enumFingerprints = changes.enumFingerprints;
		state.staticInitializerFingerprints = changes.staticInitializerFingerprints;
		state.instanceInitializerFingerprints = changes.instanceInitializerFingerprints;
		state.dirty = false;
	}

	function hasSourceModuleImport(imports:Array<String>):Bool {
		for (importPath in imports)
			if (sourceModuleForDependency(importPath) != null)
				return true;
		return false;
	}

	static function lastPathSegment(path:String):String {
		return compiler.QualifiedName.last(path);
	}

	static function firstPathSegment(path:String):String {
		return compiler.QualifiedName.first(path);
	}

	static function parentPath(path:String):String {
		return compiler.QualifiedName.parentOrEmpty(path);
	}

	static function mergeChanges(target:Map<String, Bool>, source:Map<String, Bool>):Void {
		for (name in source.keys())
			target.set(name, true);
	}

	static function mapIsEmpty(values:Map<String, Bool>):Bool {
		for (_ in values.keys())
			return false;
		return true;
	}

	function importAliases(imports:Array<String>, explicit:Map<String, String>):Map<String, String> {
		var aliases:Map<String, String> = [];
		for (path in imports) {
			var alias = lastPathSegment(path);
			aliases.set(alias, importedDeclarationName(path));
			aliases.set(path, importedDeclarationName(path));
		}
		for (alias => path in explicit) {
			aliases.set(alias, importedDeclarationName(path));
			aliases.set(path, importedDeclarationName(path));
		}
		return aliases;
	}

	function importedDeclarationName(path:String):String {
		var sourceModule = sourceModuleForDependency(path);
		if (sourceModule == null)
			return path;
		var moduleName:String = sourceModule;
		if (moduleName == path)
			return path;
		var packageName = parentPath(moduleName),
			nestedStart = moduleName.length + 1,
			nestedName = path.substring(nestedStart, path.length);
		return packageName.length == 0 ? nestedName : packageName + "." + nestedName;
	}

	function nativePrefixExists(prefix:String):Bool
		return natives.hasChild(prefix);

	function sourceModuleForDependency(path:String):Null<String> {
		var candidate = path;
		while (true) {
			if (modules.exists(candidate))
				return candidate;
			var parent = parentPath(candidate);
			if (parent.length == 0)
				return null;
			candidate = parent;
		}
	}

	static function isPlatformDependency(path:String):Bool {
		var root = firstPathSegment(path);
		return root == "haxe" || root == "sys" || root == "hl" || root == "Array" || root == "String" || root == "Math" || root == "Reflect"
			|| root == "Std" || root == "StringTools" || root == "Type";
	}

	static function signatureFingerprint(fn:AstFunction, aliases:Array<compiler.Ast.AstTypeAlias>):String
		return SemanticSignature.parsedFunction(fn, aliases);

	static function owner(name:String, entry:String):String {
		var first = firstPathSegment(name);
		return first == name ? entry : first;
	}

	static function copyIndices(source:Map<String, Int>):Map<String, Int> {
		var result:Map<String, Int> = [];
		for (name => index in source)
			result.set(name, index);
		return result;
	}
}
