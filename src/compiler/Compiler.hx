package compiler;

import compiler.syntax.Ast;
import compiler.syntax.Ast.AstFunction;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.IrGenerator;
import compiler.types.SignatureInference;
import compiler.types.Typer;
import compiler.types.Typer.TyperPhaseMetrics;
import compiler.semantic.GenericSpecializationRegistry;
import compiler.semantic.SemanticProgram;
import compiler.types.TypedAst.TypedProgram;
import compiler.hl.HlCode;
import compiler.hl.incremental.HlModuleAssembler;
import compiler.hl.patch.HlPatchWriter;
import compiler.hl.persistence.HlRuntimeIdentity;
import compiler.hl.persistence.HlAssemblerStateCodec;
import haxe.io.Bytes;
import compiler.types.Type.CompilerType;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrCNative;
import compiler.ir.Ir.IrObject;
import compiler.types.TypeRegistry;
import compiler.types.TypeRegistry.TypeCompatibility;
import compiler.service.CancellationToken;
import compiler.service.CancellationError;
import compiler.abi.RuntimeAbi;
import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;
import compiler.abi.PatchPlanner;
import compiler.abi.PatchPlanner.AbiChange;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.runtime.NativeRegistry;
import compiler.runtime.NativeRegistry.NativeDefinition;
import compiler.compilation.AnalysisTransaction;
import compiler.compilation.CompilationTransaction;
import compiler.compilation.CompilerPublication;
import compiler.compilation.CompilerPublication.CompilerSnapshot;
import compiler.compilation.CompilerPublication.PublicationStatus;
import compiler.compilation.CompilerPublication.ReconnectDecision;
import compiler.compilation.CompilerPublication.ReconnectReason;
import compiler.modules.ModuleGraph;
import compiler.modules.ModulePath;
import compiler.modules.ModuleState;
import compiler.modules.ModuleSourceLoader;
import compiler.semantic.ModuleCanonicalizer;
import compiler.semantic.LambdaCollector;
import compiler.semantic.SemanticWorkspace;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiAbi;
import compiler.ffi.HxiParser;
import compiler.ffi.HxiValidator;
import compiler.ffi.HxiProjection;
import compiler.ffi.HxiProjectionProfile;

typedef FfiInterfaceSource = {
	final path:String;
	final text:String;
}

typedef FfiProjectionSource = {
	final path:String;
	final text:String;
}

/** Immutable source snapshot used when rebuilding a compiler candidate. */
class FfiConfiguration {
	final interfaces:Array<FfiInterfaceSource>;
	final projections:Array<FfiProjectionSource>;

	public function new(?interfaces:Array<FfiInterfaceSource>, ?projections:Array<FfiProjectionSource>) {
		this.interfaces = interfaces == null ? [] : [for (source in interfaces) {path: source.path, text: source.text}];
		this.projections = projections == null ? [] : [for (source in projections) {path: source.path, text: source.text}];
	}

	public function interfaceSources():Array<FfiInterfaceSource>
		return [for (source in interfaces) {path: source.path, text: source.text}];

	public function projectionSources():Array<FfiProjectionSource>
		return [for (source in projections) {path: source.path, text: source.text}];
}

typedef FfiComposition = {
	final omitted:Map<String, Bool>;
	final declarations:Map<String, HxiDeclaration>;
}

/** Public alias for a host-native declaration accepted by the compiler. */
typedef NativeFunction = NativeDefinition;

/** Artifacts, invalidation details, and publication metadata from a successful build. */
typedef CompileResult = {
	final ir:IrProgram;
	final module:HlCode;
	final retyped:Array<String>;
	final invalidations:Array<compiler.semantic.Invalidation.InvalidatedArtifact>;
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
	final declarationMs:Float;
	final shapeConnectionMs:Float;
	final signatureTypingMs:Float;
	final typerSetupMs:Float;
	final typerNoReturnMs:Float;
	final typerMetadataMs:Float;
	final typerBodiesMs:Float;
	final bodyTransitionMs:Float;
	final typerAssemblyMs:Float;
	final finalizationTransitionMs:Float;
	final irAssemblyMs:Float;
	final abiPlanningMs:Float;
	final backendAssemblyMs:Float;
	final patchEncodingMs:Float;
	final finalizeMs:Float;
	final modules:Int;
	final retypedFunctions:Int;
	final invalidatedArtifacts:Int;
	final invalidationReasons:Int;
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

/** Semantic analysis completed without runtime artifact assembly or publication. */
typedef AnalysisResult = {
	final moduleNames:Array<String>;
	final retyped:Array<String>;
	final diagnosticModules:Array<String>;
	final elapsedMs:Float;
}

/**
 * Persistent incremental compiler and owner of all module and backend state.
 * Compilation is transactional: failed edits do not replace published artifacts.
 */
@:allow(compiler.compilation.CompilationTransaction)
@:allow(compiler.compilation.AnalysisTransaction)
@:allow(compiler.compilation.CompilationContext)
class Compiler {
	var genericSpecializations:GenericSpecializationRegistry;

	public final modules:Map<String, ModuleState> = [];
	public final semanticWorkspace:SemanticWorkspace;
	public var configurationIdentity(default, null):String = "default";

	var configurationScopeIdentity:String = "default";
	var defines:Map<String, String> = [];

	/** Last successfully assembled typed program; failed edits never replace it. */
	public var lastTypedProgram:Null<TypedProgram> = null;

	final graph = new ModuleGraph();
	var sourceLoader = new ModuleSourceLoader();
	var assembler:HlModuleAssembler;
	final moduleId:Bytes;

	public var types(default, null):TypeRegistry;

	final natives:NativeRegistry;
	final ffiInterfaceSources:Array<FfiInterfaceSource> = [];
	final ffiInterfaceModels:Map<String, HxiInterface> = [];
	final ffiProjectionSources:Array<FfiProjectionSource> = [];
	final ffiProjectionProfiles:Map<String, HxiProjectionProfile> = [];
	final ffiProjectionPaths:Map<String, String> = [];
	final ffiProjectionCache:Map<String, String> = [];
	final ffiCompositionCache:Map<String, FfiComposition> = [];
	final ffiAbiCache:Map<String, HxiAbi> = [];
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
	/** Snapshot metadata used to retain live objects for untouched modules. */
	var snapshotModules:Null<Map<String, ModuleState>>;
	var snapshotOrigins:Null<Map<String, ModuleState>>;
	/** Serializes source mutation with transactional snapshot publication. */
	final sourceMutex = new sys.thread.Mutex();

	function withSourceLock<T>(work:Void->T):T {
		sourceMutex.acquire();
		try {
			var result = work();
			sourceMutex.release();
			return result;
		} catch (error:Dynamic) {
			sourceMutex.release();
			throw error;
		}
	}

	public function new(?identityState:Bytes, ?nativeConfiguration:Array<NativeFunction>, ?ffiConfiguration:FfiConfiguration) {
		semanticWorkspace = new SemanticWorkspace(modules);
		natives = new NativeRegistry(nativeConfiguration);
		if (identityState == null) {
			genericSpecializations = new GenericSpecializationRegistry();
			moduleId = HlRuntimeIdentity.createModuleId();
			assembler = new HlModuleAssembler();
			types = new TypeRegistry();
		} else {
			var identity = HlRuntimeIdentity.decodePersistent(identityState);
			genericSpecializations = new GenericSpecializationRegistry(identity.specializationState);
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
		if (ffiConfiguration != null) {
			for (source in ffiConfiguration.interfaceSources())
				registerFfiInterface(source.path, source.text, false);
			for (source in ffiConfiguration.projectionSources())
				registerFfiProjection(source.path, source.text, false);
		}
	}

	public function exportIdentityState():Bytes {
		var state = publication.persistence();
		var backend = state.tracking && state.revision > 0 ? HlAssemblerStateCodec.encode(assembler) : null;
		return HlRuntimeIdentity.encodePersistent(moduleId, assembler.cache.stableIds, types.exportState(), publishedAbi, state.tracking, state.revision,
			state.abi, backend, genericSpecializations.exportState());
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
		withSourceLock(function():Void {
			var candidate = publication.reject(revision);
			// A newer edit may have arrived while the runtime publication was
			// pending. Restore the compiler/runtime baseline without rolling back
			// source modules that now belong to that newer generation.
			restore(candidate.snapshot, sourceGeneration == candidate.sourceGeneration);
			assembler = candidate.assembler;
		});
	}

	public function registerNative(name:String, library:String, symbol:String, arguments:Array<CompilerType>, result:CompilerType,
			?generatedFunctionDependencies:Array<String>):Void {
		if (compiledOnce)
			throw "Native registrations are frozen after the first compilation";
		natives.registerNative(name, library, symbol, arguments, result, generatedFunctionDependencies);
	}

	public function nativeConfiguration():Array<NativeFunction> {
		return natives.configuration();
	}

	/** Monotonic source/configuration generation used by transactional publication. */
	public function currentSourceGeneration():Int
		return sourceGeneration;

	/** Whether work captured at a source generation may still be published. */
	public function isSourceGenerationCurrent(generation:Int):Bool
		return sourceGeneration == generation;

	/** Parse and register one immutable target-specific ABI interface before compilation. */
	public function addFfiInterface(path:String, source:String):Void {
		registerFfiInterface(path, source, true);
	}

	/** Register Haxe-only naming policy without changing the generated ABI model. */
	public function addFfiProjection(path:String, source:String):Void {
		registerFfiProjection(path, source, true);
	}

	function registerFfiProjection(path:String, source:String, enforceFreeze:Bool):Void {
		if (enforceFreeze && compiledOnce)
			throw "FFI projections are frozen after the first compilation";
		var profile = HxiProjectionProfile.parse(path, source),
			name = profile.interfaceName;
		if (name == null)
			throw 'FFI projection "$path" does not name an interface';
		if (ffiProjectionProfiles.exists(name))
			throw 'FFI projection for interface "$name" is already registered';
		var model = ffiInterfaceModels.get(name);
		if (model != null) {
			var composition = ffiComposition(model);
			HxiProjection.validateProfile(path, model, composition.omitted, composition.declarations, profile);
		}
		ffiProjectionProfiles.set(name, profile);
		ffiProjectionPaths.set(name, path);
		ffiProjectionSources.push({path: path, text: source});
		if (model != null) {
			ffiProjectionCache.remove(name);
			refreshFfiProjection(model);
		}
	}

	function registerFfiInterface(path:String, source:String, enforceFreeze:Bool):Void {
		if (enforceFreeze && compiledOnce)
			throw "FFI interfaces are frozen after the first compilation";
		var model = HxiParser.parse(path, source);
		if (ffiInterfaceModels.exists(model.name))
			throw 'FFI interface "${model.name}" is already registered';
		var dependencies:Array<HxiInterface> = [];
		for (dependencyName in model.dependencies) {
			var dependency = ffiInterfaceModels.get(dependencyName);
			if (dependency != null)
				dependencies.push(dependency);
		}
		HxiValidator.validateComposition(model, dependencies);
		var composition = buildFfiComposition(model),
			profile = ffiProjectionProfiles.get(model.name);
		if (profile != null)
			HxiProjection.validateProfile(ffiProjectionPaths.get(model.name), model, composition.omitted, composition.declarations, profile);
		ffiInterfaceModels.set(model.name, model);
		ffiInterfaceSources.push({path: path, text: source});
		ffiCompositionCache.set(model.name, composition);
		refreshFfiProjection(model);
	}

	/** Validated ABI interfaces in deterministic interface-name order. */
	public function ffiInterfaces():Array<HxiInterface> {
		var names = [for (name in ffiInterfaceModels.keys()) name];
		names.sort(Reflect.compare);
		return [for (name in names) ffiInterfaceModels.get(name)];
	}

	public function irCNatives():Array<IrCNative> {
		for (name in sortedFfiProjectionNames())
			if (!ffiInterfaceModels.exists(name))
				throw 'FFI projection "${ffiProjectionPaths.get(name)}" names unknown interface "$name"';
		var result:Array<IrCNative> = [];
		for (model in ffiInterfaces()) {
			var composition = ffiComposition(model);
			for (native in HxiProjection.cNatives(model, composition.omitted, composition.declarations, ffiAbi(model, composition),
				ffiProjectionProfiles.get(model.name)))
				result.push(native);
		}
		return result;
	}

	function refreshFfiProjection(model:HxiInterface):Void {
		var projection = ffiProjectionCache.get(model.name);
		if (projection == null) {
			var composition = ffiComposition(model);
			projection = HxiProjection.source(model, composition.omitted, composition.declarations, ffiAbi(model, composition),
				ffiProjectionProfiles.get(model.name));
			ffiProjectionCache.set(model.name, projection);
		}
		if (projection.length > 0)
			update(model.name + ".hx", projection);
		else
			sourceGeneration++;
	}

	function ffiAbi(model:HxiInterface, composition:FfiComposition):HxiAbi {
		var abi = ffiAbiCache.get(model.name);
		if (abi == null) {
			abi = HxiAbi.forInterface(model, composition.declarations);
			ffiAbiCache.set(model.name, abi);
		}
		return abi;
	}

	function ffiComposition(model:HxiInterface):FfiComposition {
		var cached = ffiCompositionCache.get(model.name);
		if (cached != null)
			return cached;
		var result = buildFfiComposition(model);
		ffiCompositionCache.set(model.name, result);
		return result;
	}

	function buildFfiComposition(model:HxiInterface):FfiComposition {
		// Imported HXI files can repeat declarations from included headers. Keep
		// those snapshots available for ABI classification, but emit each shared
		// declaration and native symbol from its owning interface only.
		var omitted:Map<String, Bool> = [],
			declarations:Map<String, HxiDeclaration> = [],
			visited:Map<String, Bool> = [],
			active:Map<String, Bool> = [];
		for (dependency in model.dependencies)
			collectFfiDependency(model.name, dependency, omitted, declarations, visited, active);
		return {omitted: omitted, declarations: declarations};
	}

	function sortedFfiProjectionNames():Array<String> {
		var names = [for (name in ffiProjectionProfiles.keys()) name];
		names.sort(Reflect.compare);
		return names;
	}

	function collectFfiDependency(owner:String, name:String, omitted:Map<String, Bool>, declarations:Map<String, HxiDeclaration>, visited:Map<String, Bool>,
			active:Map<String, Bool>):Void {
		if (active.get(name) == true)
			throw 'Cyclic HXI dependency involving "$owner" and "$name"';
		if (visited.get(name) == true)
			return;
		var dependency = ffiInterfaceModels.get(name);
		if (dependency == null)
			throw 'FFI interface "$owner" depends on unknown interface "$name"';
		active.set(name, true);
		for (nested in dependency.dependencies)
			collectFfiDependency(owner, nested, omitted, declarations, visited, active);
		active.remove(name);
		visited.set(name, true);
		for (declaration in dependency.declarations) {
			var declarationName = ffiDeclarationName(declaration);
			omitted.set(declarationName, true);
			if (!declarations.exists(declarationName))
				declarations.set(declarationName, declaration);
		}
	}

	static function ffiDeclarationName(declaration:HxiDeclaration):String
		return switch declaration {
			case Opaque(name, _) | Alias(name, _, _) | Handle(name, _, _, _) | Constant(name, _, _) | Structure(name, _, _, _, _) |
				Enumeration(name, _, _, _, _) | Callback(name, _, _, _, _) | Function(name, _, _, _, _, _, _, _): name;
		};

	function ffiConfigurationSnapshot():FfiConfiguration
		return new FfiConfiguration(ffiInterfaceSources, ffiProjectionSources);

	/** Add a filesystem root whose modules are loaded on demand during resolution. */
	public function addSourceRoot(path:String):Void {
		withSourceLock(function():Void {
			sourceLoader.addRoot(path);
			sourceGeneration++;
		});
	}

	/** Add a package-scoped source root for a resolved local dependency. */
	public function addPackageSourceRoot(packageName:String, path:String):Void {
		withSourceLock(function():Void {
			sourceLoader.addPackageRoot(packageName, path);
			sourceGeneration++;
		});
	}

	/**
	 * Materialize one source-root dependency for editor queries.
	 *
	 * This is intentionally limited to source loading. Parsing, recovery, and
	 * semantic publication remain owned by LanguageService, while compilation
	 * still performs its normal transactional dependency discovery.
	 */
	public function loadSourceModule(name:String):Null<ModuleState> {
		return withSourceLock(function():Null<ModuleState> {
			var existing = modules.get(name);
			if (existing != null)
				return existing;
			var state = sourceLoader.loadDependency(name, modules);
			if (state != null) {
				sourceGeneration++;
				semanticWorkspace.invalidateResolutionCache();
			}
			return state;
		});
	}

	/** Materialize direct source modules in a package for wildcard imports. */
	public function loadSourcePackage(packageName:String):Array<ModuleState> {
		return withSourceLock(function():Array<ModuleState> {
			var before = moduleCount(), result = sourceLoader.loadPackage(packageName, modules);
			if (moduleCount() != before) {
				sourceGeneration++;
				semanticWorkspace.invalidateResolutionCache();
			}
			return result;
		});
	}

	function moduleCount():Int {
		var result = 0;
		for (_ in modules)
			result++;
		return result;
	}

	public function compact(entryModule:String):CompileResult {
		var result = new CompilationTransaction(this, entryModule, null, new HlModuleAssembler(assembler.cache.stableIds)).run();
		rememberCompile(entryModule, result);
		return result;
	}

	public function update(path:String, source:String):ModuleState {
		return withSourceLock(function():ModuleState return updateSource(path, source));
	}

	function updateSource(path:String, source:String):ModuleState {
		var name = moduleNameForPath(path);
		if (modules.exists(name)) {
			var current:ModuleState = modules.get(name);
			if (current.source.path == path && current.source.text == source)
				return current;
		}
		var file = new SourceFile(path, source);
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

	/** Remove a source module and invalidate graph/cached compilation state. */
	public function remove(path:String):Bool {
		return withSourceLock(function():Bool {
			var name = moduleNameForPath(path);
			if (!modules.exists(name))
				return false;
			modules.remove(name);
			graph.rebuild(modules);
			sourceGeneration++;
			return true;
		});
	}

	/** Prefer a materialized logical module over a disk-path-derived name. */
	function moduleNameForPath(path:String):String {
		var direct = ModulePath.fromFile(path);
		if (modules.exists(direct))
			return direct;
		for (state in modules)
			if (state.source.path == path)
				return state.name;
		return direct;
	}

	/** Change semantic build context and invalidate every source-derived cache. */
	public function configure(identity:String, scopeIdentity:String, values:Array<String>):Void {
		withSourceLock(function():Void {
			configureSource(identity, scopeIdentity, values);
		});
	}

	function configureSource(identity:String, scopeIdentity:String, values:Array<String>):Void {
		var nextDefines:Map<String, String> = [];
		for (value in values) {
			var separator = value.indexOf("="),
				name = separator < 0 ? value : value.substr(0, separator);
			nextDefines.set(name, separator < 0 ? "1" : value.substr(separator + 1));
		}
		if (identity == configurationIdentity
			&& scopeIdentity == configurationScopeIdentity
			&& sameDefines(defines, nextDefines))
			return;
		var changed:Map<String, Bool> = [];
		for (name => value in defines)
			if (nextDefines.get(name) != value)
				changed.set(name, true);
		for (name => value in nextDefines)
			if (defines.get(name) != value)
				changed.set(name, true);
		var scopeChanged = scopeIdentity != configurationScopeIdentity;
		configurationIdentity = identity;
		configurationScopeIdentity = scopeIdentity;
		defines = nextDefines;
		for (state in modules) {
			var affected = scopeChanged;
			if (!affected)
				for (name in state.conditionalDefines)
					if (changed.exists(name)) {
						affected = true;
						break;
					}
			if (affected)
				state.update(new SourceFile(state.source.path, state.source.text));
		}
		sourceGeneration++;
	}

	static function sameDefines(left:Map<String, String>, right:Map<String, String>):Bool {
		var leftCount = 0;
		for (name => value in left) {
			leftCount++;
			if (!right.exists(name) || right.get(name) != value)
				return false;
		}
		var rightCount = 0;
		for (_ in right)
			rightCount++;
		return leftCount == rightCount;
	}

	/** Update semantic state without assembling or publishing a runtime artifact. */
	public function analyze(entryModule:String, ?token:CancellationToken):AnalysisResult
		return new AnalysisTransaction(this, entryModule, token).run();

	public function dependentModules(module:String):Array<String>
		return graph.dependents(module);

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
		var candidate = new Compiler(exportIdentityState(), nativeConfiguration(), ffiConfigurationSnapshot());
		candidate.sourceLoader = sourceLoader.copy();
		candidate.configurationIdentity = configurationIdentity;
		candidate.configurationScopeIdentity = configurationScopeIdentity;
		candidate.defines = [for (name => value in defines) name => value];
		var moduleNames = [for (name in modules.keys()) name];
		moduleNames.sort(Reflect.compare);
		for (name in moduleNames) {
			var state:ModuleState = modules.get(name);
			candidate.update(state.source.path, state.source.text);
		}
		return candidate;
	}

	public function compile(entryModule:String, ?token:CancellationToken, ?indexSemantics = true):CompileResult {
		var generation = sourceGeneration,
			cached = cachedCompileResult, cachedEntry = cachedCompileEntry;
		if (!publication.status().tracking
			&& cached != null
			&& cachedCompileGeneration == generation
			&& cachedEntry != null
			&& cachedEntry == entryModule) {
			if (token != null)
				token.check();
			if (!isSourceGenerationCurrent(generation))
				throw new CancellationError();
			return {
				ir: cached.ir,
				module: cached.module,
				retyped: [],
				invalidations: [],
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
					declarationMs: 0.0,
					shapeConnectionMs: 0.0,
					signatureTypingMs: 0.0,
					typerSetupMs: 0.0,
					typerNoReturnMs: 0.0,
					typerMetadataMs: 0.0,
					typerBodiesMs: 0.0,
					bodyTransitionMs: 0.0,
					typerAssemblyMs: 0.0,
					finalizationTransitionMs: 0.0,
					irAssemblyMs: 0.0,
					abiPlanningMs: 0.0,
					backendAssemblyMs: 0.0,
					patchEncodingMs: 0.0,
					finalizeMs: 0.0,
					modules: cached.metrics.modules,
					retypedFunctions: 0,
					invalidatedArtifacts: 0,
					invalidationReasons: 0,
					regeneratedFunctions: 0,
					changedFunctions: 0,
					moduleFunctions: cached.metrics.moduleFunctions,
					moduleNatives: cached.metrics.moduleNatives,
					patchBytes: 0
				}
			};
		}
		var result = new CompilationTransaction(this, entryModule, token, null, indexSemantics).run();
		rememberCompile(entryModule, result);
		return result;
	}

	function rememberCompile(entryModule:String, result:CompileResult):Void {
		cachedCompileGeneration = sourceGeneration;
		cachedCompileEntry = entryModule;
		cachedCompileResult = result;
	}

	function executableEntryPoint(entryModule:String):String {
		var state:ModuleState = modules.get(entryModule),
			ast = state.parsedAst();
		for (fn in ast.functions)
			if (fn.name == "main")
				return "main";
		for (classDecl in ast.classes)
			for (method in classDecl.methods)
				if (method.name == "main" && method.isStatic)
					return ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name) + ".main";
		return "main";
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
		return withSourceLock(function():CompilerSnapshot return snapshotSource());
	}

	function snapshotSource():CompilerSnapshot {
		var moduleCopies:Map<String, ModuleState> = [],
			originalModules:Map<String, ModuleState> = [],
			objectCopies:Map<String, IrObject> = [];
		for (name => state in modules) {
			originalModules.set(name, state);
			moduleCopies.set(name, state.copy());
		}
		for (name => object in objectCache)
			objectCopies.set(name, object);
		return {
			modules: moduleCopies,
			originalModules: originalModules,
			types: types.copy(),
			objectCache: objectCopies,
			lastTypedProgram: lastTypedProgram,
			publishedAbi: publishedAbi,
			compiledOnce: compiledOnce,
			rehydrationBaseline: rehydrationBaseline,
			semanticProgram: cachedSemanticProgram
		};
	}

	function createCandidate(snapshot:CompilerSnapshot, startingAssembler:Null<HlModuleAssembler>):Compiler {
		var candidate = new Compiler(exportIdentityState(), nativeConfiguration(), ffiConfigurationSnapshot());
		candidate.sourceLoader = sourceLoader.copy();
		candidate.configurationIdentity = configurationIdentity;
		candidate.configurationScopeIdentity = configurationScopeIdentity;
		candidate.defines = [for (name => value in defines) name => value];
		for (name in [for (name in candidate.modules.keys()) name])
			candidate.modules.remove(name);
		for (name => state in snapshot.modules)
			candidate.modules.set(name, state);
		candidate.snapshotModules = snapshot.modules;
		candidate.snapshotOrigins = snapshot.originalModules;
		candidate.types = snapshot.types.copy();
		candidate.objectCache = [for (name => object in snapshot.objectCache) name => object];
		candidate.lastTypedProgram = snapshot.lastTypedProgram;
		candidate.publishedAbi = snapshot.publishedAbi;
		candidate.compiledOnce = snapshot.compiledOnce;
		candidate.rehydrationBaseline = snapshot.rehydrationBaseline;
		candidate.cachedSemanticProgram = snapshot.semanticProgram;
		candidate.genericSpecializations = genericSpecializations.copy();
		candidate.assembler = startingAssembler == null ? assembler : startingAssembler;
		return candidate;
	}

	function adoptCandidate(candidate:Compiler, generation:Int):Void {
		withSourceLock(function():Void {
			if (!isSourceGenerationCurrent(generation))
				throw new CancellationError();
			adoptCandidateSource(candidate);
		});
	}

	function publishCandidate(candidate:Compiler, generation:Int, revision:Int, abi:RuntimeAbiDescriptor,
		snapshot:CompilerSnapshot, previousAssembler:HlModuleAssembler):Void {
		withSourceLock(function():Void {
			if (!isSourceGenerationCurrent(generation))
				throw new CancellationError();
			adoptCandidateSource(candidate);
			publication.candidate(revision, generation, abi, snapshot, previousAssembler);
		});
	}

	function adoptCandidateSource(candidate:Compiler):Void {
		for (name in [for (name in modules.keys()) name])
			modules.remove(name);
		for (name => state in candidate.modules) {
			var origin = candidate.snapshotOrigins == null ? null : candidate.snapshotOrigins.get(name),
				originalSnapshot = candidate.snapshotModules == null ? null : candidate.snapshotModules.get(name);
			modules.set(name, origin != null && originalSnapshot == state ? origin : state);
		}
		types = candidate.types;
		objectCache = candidate.objectCache;
		lastTypedProgram = candidate.lastTypedProgram;
		publishedAbi = candidate.publishedAbi;
		compiledOnce = candidate.compiledOnce;
		rehydrationBaseline = candidate.rehydrationBaseline;
		cachedSemanticProgram = candidate.cachedSemanticProgram;
		assembler = candidate.assembler;
		genericSpecializations = candidate.genericSpecializations;
		graph.rebuild(modules);
	}

	function writableState(name:String, rollbackModules:Map<String, ModuleState>):ModuleState {
		var state:ModuleState = modules.get(name);
		if (rollbackModules.get(name) == state) {
			state = state.copy();
			modules.set(name, state);
		}
		return state;
	}

	function restore(snapshot:CompilerSnapshot, restoreModules:Bool = true):Void {
		if (restoreModules) {
			for (name in [for (name in modules.keys()) name])
				modules.remove(name);
			for (name => state in snapshot.modules)
				modules.set(name, state);
		}
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

	/** Select the C ABI used by native-layout queries and source records. */
	public function nativeLayoutTarget():String {
		var configured = defines.get("native-abi-target");
		if (configured != null)
			return configured;
		var interfaceTarget:Null<String> = null;
		for (model in ffiInterfaces()) {
			if (interfaceTarget == null)
				interfaceTarget = model.target;
			else if (interfaceTarget != model.target)
				throw 'Native layout queries require one HXI target, found "$interfaceTarget" and "${model.target}"';
		}
		if (interfaceTarget != null)
			return interfaceTarget;
		return switch (defines.get("target")) {
			case "wasm32" | "wasmgc" | "wasm-gc": "portable-abi32";
			case "wasm64": "portable-abi64";
			case "hl" | null: "portable-abi64";
			case target: target;
		}
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

	static function mapIsEmpty(values:Map<String, Bool>):Bool {
		for (_ in values.keys())
			return false;
		return true;
	}

	static function copyIndices(source:Map<String, Int>):Map<String, Int> {
		var result:Map<String, Int> = [];
		for (name => index in source)
			result.set(name, index);
		return result;
	}
}
