package compiler;

import compiler.core.InternalError;
import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceFile;
import compiler.ir.model.Ir.IrProgram;
import compiler.backend.Backend.BackendTarget;
import compiler.backend.BackendTargets;
import compiler.ir.model.Ir.IrType;
import compiler.types.Typer;
import compiler.types.Typer.TyperPhaseMetrics;
import compiler.semantic.GenericSpecializationRegistry;
import compiler.types.TypedAst.TypedProgram;
import compiler.hl.incremental.HlModuleAssembler;
import compiler.hl.persistence.HlRuntimeIdentity;
import compiler.hl.persistence.HlAssemblerStateCodec;
import haxe.io.Bytes;
import compiler.types.Type.CompilerType;
import compiler.types.TypeRegistry;
import compiler.core.CancellationToken;
import compiler.abi.PatchPlanner;
import compiler.abi.PatchPlanner.AbiChange;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.runtime.NativeRegistry;
import compiler.runtime.NativeRegistry.NativeDefinition;
import compiler.compilation.AnalysisTransaction;
import compiler.compilation.BackendArtifact;
import compiler.compilation.BackendSession;
import compiler.compilation.HashLinkBackendSession;
import compiler.compilation.WasmBackendSession;
import compiler.compilation.CompilationContext;
import compiler.compilation.CompilationPipeline;
import compiler.compilation.CompilationTransaction;
import compiler.compilation.FrontendCompilation;
import compiler.compilation.CompilerPublication;
import compiler.compilation.SessionState;
import compiler.compilation.CompilerPublication.PublicationStatus;
import compiler.compilation.CompilerPublication.ReconnectDecision;
import compiler.compilation.CompilerPublication.ReconnectReason;
import compiler.modules.ModuleGraph;
import compiler.modules.ModulePath;
import compiler.modules.ModuleState;
import compiler.modules.ModuleSourceLoader;
import compiler.semantic.SemanticWorkspace;
import compiler.ffi.FfiRegistry;
import compiler.ffi.FfiRegistry.FfiConfiguration;

/** Public alias for a host-native declaration accepted by the compiler. */
typedef NativeFunction = NativeDefinition;

/** Artifacts, invalidation details, and publication metadata from a successful build. */
typedef CompileResult = {
	/**
	 * The program the backends were given: for a plain HashLink build that is the emitted program, already pruned at the prune point of the
	 * pipeline (`IrEntryPrune`), so it has no function nothing reaches; a live or Wasm build's program is complete.
	 */
	final ir:IrProgram;

	/** What the backend emitted: a HashLink module with its identity and patch, or a Wasm module. */
	final artifact:compiler.compilation.BackendArtifact;

	final retyped:Array<String>;
	final invalidations:Array<compiler.semantic.Invalidation.InvalidatedArtifact>;
	final regenerated:Array<String>;
	final changedFunctions:Array<Int>;
	final requiresReload:Bool;
	final reloadReasons:Array<AbiChange>;

	/** The modules of the compiled program (every module the frontend reached), sorted by name. */
	/** The native type descriptors of the typed program, for the `.descriptors` files beside the module. */
	final nativeTypeDescriptors:Array<compiler.types.NativeTypeDescriptor.NativeTypeDescriptorData>;

	final moduleNames:Array<String>;

	/** No runtime publication is required; revision stays at the acknowledged baseline. */
	final unchanged:Bool;

	final revision:Int;

	/** The revision the artifact's patch applies to. */
	final baseRevision:Int;

	final metrics:CompileMetrics;
}

/** Work and output-size counters measured for one compilation. */
typedef CompileMetrics = {
	final allocationPhases:Array<compiler.core.AllocationMeter.PhaseAllocation>;
	final elapsedMs:Float;
	final transactionSnapshotMs:Float;
	final candidateSetupMs:Float;
	final frontendMs:Float;
	final frontendGraphMs:Float;
	final graphParseMs:Float;
	final graphDependencyMs:Float;
	final graphInitializationMs:Float;

	/** The functions the frontend typed: those an edit invalidated, or every one in a first build. */
	final frontendTypedFunctions:Int;

	/** Where the frontend's stages spent their time and allocation, as one line; empty when the frontend did not run. */
	final frontendStages:String;

	/** What each IR pass allocated, for the timings line; empty when the build reused its pipeline and ran none. */
	final irPassCosts:Array<compiler.core.IrPassMeter.IrPassCost>;

	final semanticAssemblyMs:Float;
	final semanticAliasMs:Float;
	final semanticCanonicalizationMs:Float;
	final semanticContributionReuseMs:Float;
	final semanticContributionRebuildMs:Float;
	final semanticInvalidationMs:Float;
	final semanticAllocatedBytes:Float;
	final typingLoweringMs:Float;
	final analysisMs:Float;
	final declarationMs:Float;
	final shapeConnectionMs:Float;
	final signatureTypingMs:Float;
	final typerSetupMs:Float;
	final typerNoReturnMs:Float;
	final typerMetadataMs:Float;
	final typerClassBodiesMs:Float;
	final typerFunctionBodiesMs:Float;
	final typerGeneratedMs:Float;
	final bodyTransitionMs:Float;
	final typerAssemblyMs:Float;
	final finalizationTransitionMs:Float;
	final irGenerationMs:Float;
	final irAssemblyMs:Float;
	final abiPlanningMs:Float;
	final backendAssemblyMs:Float;
	final backendAssemblerCopyMs:Float;
	final backendCachePreparationMs:Float;
	final backendLoweringMs:Float;
	final backendPublicationMs:Float;
	final backendSnapshotMs:Float;
	final backendVerificationMs:Float;
	final backendMetadataMs:Float;
	final backendFunctionLoweringMs:Float;
	final backendDebugAssemblyMs:Float;
	final backendFinalizationMs:Float;
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

	/** What an unchanged build reused: "none", "ir" (the final IR) or "ir+module" (the module as well), or "result" for a cached result. */
	final reuse:String;

	/** How many functions the module took from the last plain build's lowering instead of lowering them again. */
	final linkedFunctions:Int;

	/** How many of those were given other indices than they were lowered with. */
	final movedFunctions:Int;
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

	/** The locals of the bodies this analysis typed whose type nothing fixed (`TypedProgram.unboundLocals`). */
	final unboundLocals:Array<compiler.types.TypedAst.UnboundLocal>;

	/** The `throw`s of the bodies this analysis typed whose value is not statically a haxe.Exception (`TypedProgram.nonExceptionThrows`). */
	final nonExceptionThrows:Array<compiler.types.TypedAst.NonExceptionThrow>;

	/** The analyzed modules' variables and functions named through their module's name (AliasTable.ModuleNamespaceUse). */
	final moduleNamespaceUses:Array<compiler.semantic.AliasTable.ModuleNamespaceUse>;
}

/**
 * Persistent incremental compiler and owner of all module and backend state.
 * Compilation is transactional: failed edits do not replace published artifacts.
 */
@:allow(compiler.compilation.CompilationTransaction)
@:allow(compiler.compilation.AnalysisTransaction)
@:allow(compiler.compilation.CompilationContext)
class Compiler {
	/**
	 * What the builds own (`SessionState`): the modules, the types, the caches of the last build and the backend. A build works on a
	 * copy and replaces this state with it when it succeeds; a rejected publication puts back the state it was built from.
	 */
	public var state(default, null):SessionState;

	public var modules(get, never):Map<String, ModuleState>;
	public var semanticWorkspace(get, never):SemanticWorkspace;
	public var types(get, never):TypeRegistry;

	/** Last successfully assembled typed program; failed edits never replace it. */
	public var lastTypedProgram(get, never):Null<TypedProgram>;

	public var inlineCache(get, never):compiler.ir.passes.inlining.IrInliner.IrInlineCache;
	public var pipelineSnapshot(get, never):Null<compiler.compilation.PipelineSnapshot>;
	public var backend(get, never):BackendSession;
	public var verifyMemo(get, never):compiler.ir.verify.IrVerifyMemo;
	public var configurationIdentity(default, null):String = "default";

	var configurationScopeIdentity:String = "default";
	var defines:Map<String, String> = [];

	/** The backend the `target` define selects, parsed once by `configure`; HashLink when there is none. */
	public var backendTarget(default, null):BackendTarget = HashLink;

	var exportedFunctions:Array<String> = [];

	/**
	 * Whether backend assembly keeps its append-only history between compiles. Live sessions need it: patches
	 * address the running module by stable slots, symbol indices and function ids. When false, every compile
	 * assembles from a fresh assembler, so the module is a function of the source alone and never carries dead
	 * functions, strings or ids from earlier revisions. Frontend caches stay incremental either way.
	 */
	public var livePatching = true;

	/** Emit metadata used by development tooling in addition to runtime data. */
	public var developmentMetadata = true;

	/**
	 * Reserved slots a live HashLink build gives each object (see `HlLower.reservedSlots`): how many fields a session can
	 * add to one class before the edit needs a reload, which lays the slots out afresh. Each costs a pointer per instance.
	 */
	public var liveFieldReserve = 4;

	/**
	 * What the request asks of the backend besides the program (Wasm memory, exports, allocator options), set per request like
	 * `livePatching`; null for the target's defaults. The HashLink backend reads its options from the fields above.
	 */
	public var backendOptions:Null<compiler.backend.Backend.BackendOptions> = null;

	/**
	 * The passes and self-checks of the compiles this session runs, as its request states them (`CompileOptions`). Other
	 * options make the next compile build again, as a source edit does; the caches below it key their entries by them.
	 */
	public var options(default, set):CompileOptions = new CompileOptions();

	function set_options(value:CompileOptions):CompileOptions {
		if (value.key() != options.key())
			sourceGeneration++;
		return options = value;
	}

	final graph = new ModuleGraph();
	var sourceLoader = new ModuleSourceLoader();
	final moduleId:Bytes;

	final natives:NativeRegistry;

	/** The FFI interfaces and projections this compiler was given (`addFfiInterface`, `addFfiProjection`). */
	public final ffi:FfiRegistry;

	final publication = new CompilerPublication();
	var sourceGeneration = 0;
	var cachedCompileGeneration = -1;
	var cachedCompileEntry:Null<String>;
	var cachedCompileResult:Null<CompileResult>;

	public function new(?identityState:Bytes, ?nativeConfiguration:Array<NativeFunction>,
			?ffiConfiguration:FfiConfiguration) {
		natives = new NativeRegistry(nativeConfiguration);
		if (identityState == null) {
			moduleId = HlRuntimeIdentity.createModuleId();
			state = new SessionState(new TypeRegistry(), new GenericSpecializationRegistry(),
				new HashLinkBackendSession(new HlModuleAssembler()));
		} else {
			var identity = HlRuntimeIdentity.decodePersistent(identityState);
			moduleId = identity.moduleId;
			var assemblerState = identity.assemblerState;
			var assembler = assemblerState == null
				? new HlModuleAssembler(identity.stableIds) : HlAssemblerStateCodec.decode(assemblerState);
			for (name => id in identity.stableIds)
				if (assembler.cache.stableIds.get(name) != id)
					throw new InternalError("Assembler stable identities do not match compiler state");
			for (name => id in assembler.cache.stableIds)
				if (identity.stableIds.get(name) != id)
					throw new InternalError("Assembler stable identities do not match compiler state");
			state = new SessionState(new TypeRegistry(identity.typeState),
				new GenericSpecializationRegistry(identity.specializationState), new HashLinkBackendSession(assembler));
			state.publishedAbi = identity.publishedAbi;
			if (identity.publicationTracking)
				publication.enable(identity.acknowledgedRevision, identity.acknowledgedAbi,
					identity.assemblerState != null);
			if (identity.assemblerState != null) {
				state.compiledOnce = true;
				beginRehydration(assembler);
			}
		}
		ffi = new FfiRegistry(projectedFfiModule);
		if (ffiConfiguration != null) {
			for (source in ffiConfiguration.interfaceSources())
				ffi.registerInterface(source.path, source.text);
			for (source in ffiConfiguration.projectionSources())
				ffi.registerProjection(source.path, source.text);
		}
	}

	public function exportIdentityState():Bytes {
		var persistence = publication.persistence(),
			hashLink = state.backend.hashLink();
		// Live patching, and with it the identity a later session resumes, is HashLink's; another backend persists no layout.
		var assembler = hashLink == null ? null : hashLink.assembler,
			assemblerState = persistence.tracking && persistence.revision > 0
				&& assembler != null ? HlAssemblerStateCodec.encode(assembler) : null;
		return HlRuntimeIdentity.encodePersistent(moduleId, assembler == null ? [] : assembler.cache.stableIds,
			state.types.exportState(), state.publishedAbi, persistence.tracking, persistence.revision,
			persistence.abi, assemblerState, state.genericSpecializations.exportState());
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
		state.rehydrationBaseline = baseline;
		for (name => fn in restored.cache.functions)
			baseline.set(name, compiler.ir.codec.IrFunctionStateCodec.encode(fn));
	}

	public function acknowledgePublication(revision:Int):Void
		publication.acknowledge(revision, livePatching);

	public function rejectPublication(revision:Int):Void {
		state = publication.reject(revision).snapshot;
	}

	/**
	 * Returns to the state the module had at `revision`, which the live host still runs after refusing the revisions published
	 * since, so the next build patches the module the host has. Their edits are still in the sources and come back in that
	 * build. False when the compiler no longer holds that state.
	 */
	public function retractPublication(revision:Int):Bool {
		var current = state.backend.hashLink();
		if (current == null)
			return false;
		var latest = current.assembler.lastRevision(),
			candidate = publication.retract(revision);
		if (candidate == null)
			return false;
		state = candidate.snapshot;
		var retracted = state.backend.hashLink();
		if (retracted == null)
			return false;
		var assembler = retracted.assembler.copy();
		// The refused revisions were published; their numbers stay used.
		assembler.continueRevisions(latest);
		state.backend = new HashLinkBackendSession(assembler, retracted.loweredCache);
		return true;
	}

	public function registerNative(name:String, library:String, symbol:String, arguments:Array<CompilerType>,
			result:CompilerType,
			?generatedFunctionDependencies:Array<String>):Void {
		if (state.compiledOnce)
			throw new InternalError("Native registrations are frozen after the first compilation");
		natives.registerNative(name, library, symbol, arguments, result, generatedFunctionDependencies);
	}

	public function nativeConfiguration():Array<NativeFunction> {
		return natives.configuration();
	}

	/** Parse and register one immutable target-specific ABI interface before compilation. */
	public function addFfiInterface(path:String, source:String):Void {
		if (state.compiledOnce)
			throw new InternalError("FFI interfaces are frozen after the first compilation");
		ffi.registerInterface(path, source);
	}

	/** Register Haxe-only naming policy without changing the generated ABI model. */
	public function addFfiProjection(path:String, source:String):Void {
		if (state.compiledOnce)
			throw new InternalError("FFI projections are frozen after the first compilation");
		ffi.registerProjection(path, source);
	}

	/** A module the FFI registry projected from an interface: a source update, or with no text a change of the build inputs. */
	function projectedFfiModule(path:String, source:String):Void
		if (source.length > 0)
			update(path, source);
		else
			sourceGeneration++;

	/** Modules compiled with every entry, whatever it imports: what a host calls into (haxeon.wasm.HostError). */
	public final rootModules:Array<String> = [];

	/** Compiles a loaded module with every entry, so its exposed functions reach the output. */
	public function addRootModule(name:String):Void
		if (rootModules.indexOf(name) < 0)
			rootModules.push(name);

	/** Host-visible signatures are layout inputs, not just late backend export names. */
	public function setExportedFunctions(names:Array<String>):Void {
		if (sameExportedFunctions(names, exportedFunctions))
			return;
		var next = names.copy();
		next.sort(Reflect.compare);
		var unique:Array<String> = [];
		for (name in next)
			if (unique.length == 0 || unique[unique.length - 1] != name)
				unique.push(name);
		if (sameExportedFunctions(unique, exportedFunctions))
			return;
		exportedFunctions = unique;
		sourceGeneration++;
	}

	static function sameExportedFunctions(first:Array<String>, second:Array<String>):Bool {
		if (first.length != second.length)
			return false;
		for (index in 0...first.length)
			if (first[index] != second[index])
				return false;
		return true;
	}

	/** Add a filesystem root whose modules are loaded on demand during resolution. */
	public function addSourceRoot(path:String):Void {
		sourceLoader.addRoot(path);
		sourceGeneration++;
	}

	/** Register the compiler-owned standard library root separately from project source roots. */
	public function addStandardLibrarySourceRoot(path:String):Void {
		sourceLoader.addStandardLibraryRoot(path);
		sourceLoader.addPortableLibraryRoot(path);
		sourceGeneration++;
	}

	/** Add a package-scoped source root for a resolved local dependency. */
	public function addPackageSourceRoot(packageName:String, path:String):Void {
		sourceLoader.addPackageRoot(packageName, path);
		sourceGeneration++;
	}

	public function compact(entryModule:String):CompileResult {
		var hashLink = state.backend.hashLink();
		if (hashLink == null)
			throw new InternalError("Compacting a module is a HashLink operation");
		var result = new CompilationTransaction(this, entryModule, null, hashLink.compacting()).run();
		rememberCompile(entryModule, result);
		return result;
	}

	/** An explicit module identity keeps a standalone file's directory out of its package. */
	public function update(path:String, source:String, ?moduleName:String):ModuleState {
		var name = moduleName == null ? ModulePath.fromFile(path) : moduleName;
		var isStandardLibrarySource = false;
		if (modules.exists(name)) {
			var current:ModuleState = modules.get(name);
			if (current.source.path == path) {
				if (current.loadedText == source)
					return current;
				isStandardLibrarySource = current.source.isStandardLibrarySource;
			}
		}
		var file = new SourceFile(path, source, isStandardLibrarySource);
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

	/** Refresh a lazily loaded module without deriving its name from its absolute source path. */
	public function refreshLoadedSource(name:String, source:String):Void {
		var state = modules.get(name);
		if (state == null)
			throw new InternalError('Cannot refresh unloaded module "$name"');
		if (state.loadedText != source) {
			state.update(new SourceFile(state.source.path, source, state.source.isStandardLibrarySource));
			sourceGeneration++;
		}
	}

	/** Remove a source module and invalidate graph/cached compilation state. */
	public function remove(path:String):Bool {
		var name = ModulePath.fromFile(path);
		if (!modules.exists(name))
			return false;
		modules.remove(name);
		state.declarationOwners.release(name);
		graph.rebuild(modules);
		sourceGeneration++;
		return true;
	}

	/** Normalize command-line defines consistently for parsing and session invalidation. */
	public static function defineMap(values:Array<String>):Map<String, String> {
		var result:Map<String, String> = [];
		for (value in values) {
			var separator = value.indexOf("="),
				name = separator < 0 ? value : value.substr(0, separator);
			result.set(name, separator < 0 ? "1" : value.substr(separator + 1));
		}
		return result;
	}

	/** Change semantic build context and invalidate every source-derived cache. */
	public function configure(identity:String, scopeIdentity:String, values:Array<String>):Void {
		if (identity == configurationIdentity)
			return;
		var nextDefines = defineMap(values);
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
		var target = BackendTargets.parse(nextDefines.get("target"));
		backendTarget = target == null ? HashLink : target;
		// The session's backend builds for the target; one that builds for another starts over.
		if (state.backend.backendTarget() != backendTarget)
			state.backend = switch backendTarget {
				case HashLink: new HashLinkBackendSession(new HlModuleAssembler());
				case HashLinkC: new compiler.compilation.HlcBackendSession();
				case Wasm32 | Wasm64 | WasmGc: new WasmBackendSession(backendTarget);
			};
		for (module in modules) {
			var affected = scopeChanged;
			if (!affected)
				for (name in module.conditionalDefines)
					if (changed.exists(name)) {
						affected = true;
						break;
					}
			if (affected)
				module.render(new SourceFile(module.source.path, module.source.text,
					module.source.isStandardLibrarySource));
		}
		sourceGeneration++;
	}

	/**
	 * Update semantic state without assembling or publishing a runtime artifact. `requireEntry` fails it, as a build fails, when the
	 * program has no executable entry point.
	 */
	public function analyze(entryModule:String, ?token:CancellationToken, requireEntry = false):AnalysisResult
		return new AnalysisTransaction(this, entryModule, token, requireEntry).run();

	public function dependentModules(module:String):Array<String>
		return graph.dependents(module);

	/**
	 * Whether an unsaved edit types: the frontend runs on a copy of the state with the edit, and the copy is dropped, so this
	 * compiler is left as it was. The edited file keeps the module name it has.
	 */
	public function validate(path:String, source:String, entryModule:String,
			?token:CancellationToken):ValidationResult {
		var candidate = candidateWithSource(path, source, moduleNameOf(path));
		try {
			FrontendCompilation.run(new CompilationContext(this, candidate), entryModule, token, state.modules,
				Sys.time() * 1000.0, false);
			return {valid: true, diagnostic: null};
		} catch (error:CompileError)
			return {valid: false, diagnostic: error.diagnostic};
	}

	/** Compile a temporary Int-returning expression without changing this compiler. */
	public function compileExpressionInt(expression:String):CompileResult {
		var candidate = candidateWithSource("__repl__.hx",
			'function __repl_value():Int { return $expression; } function main():Int { return __repl_value(); }',
			"__repl__"),
			startedAt = Sys.time() * 1000.0;
		return CompilationPipeline.compile(new CompilationContext(this, candidate), "__repl__", null, state.modules,
			startedAt, startedAt, startedAt);
	}

	/** The module a source file holds: the one loaded from it, under whatever name it was given, or the name its path gives. */
	function moduleNameOf(path:String):String {
		for (name => module in modules)
			if (module.source.path == path)
				return name;
		return ModulePath.fromFile(path);
	}

	/** A copy of the state (`SessionState.copyForCandidate`) in which module `name` is `source`, as `update` would make it. */
	function candidateWithSource(path:String, source:String, name:String):SessionState {
		var candidate = state.copyForCandidate(), current = candidate.modules.get(name);
		if (current != null && current.source.path == path && current.loadedText == source)
			return candidate;
		var file = new SourceFile(path, source,
			current != null && current.source.path == path && current.source.isStandardLibrarySource);
		if (current == null)
			candidate.modules.set(name, new ModuleState(name, file));
		else {
			var module = current.copy();
			module.update(file);
			candidate.modules.set(name, module);
		}
		return candidate;
	}

	/** The warnings the given modules have from their last successful typing, in module and source order. */
	public function warnings(moduleNames:Array<String>):Array<Diagnostic> {
		var result:Array<Diagnostic> = [];
		for (name in moduleNames) {
			var state = modules.get(name);
			if (state != null)
				for (diagnostic in state.diagnostics)
					if (diagnostic.severity.match(Warning))
						result.push(diagnostic);
		}
		return result;
	}

	public function compile(entryModule:String, ?token:CancellationToken, ?indexSemantics = true):CompileResult {
		var cached = cachedCompileResult, cachedEntry = cachedCompileEntry;
		if (!publication.status().tracking
			&& cached != null
			&& cachedCompileGeneration == sourceGeneration
			&& cachedEntry != null
			&& cachedEntry == entryModule) {
			if (token != null)
				token.check();
			return {ir: cached.ir,
				// The module is the one the last build delivered; there is nothing to patch.
				artifact: switch cached.artifact {
					case HashLinkBuild(build): HashLinkBuild({
						module: build.module,
						functionIndices: build.functionIndices,
						functionIds: build.functionIds,
						runtimeIdentity: build.runtimeIdentity,
						patchBytes: null
					});
					case WasmBuild(build): WasmBuild(build);
					case HashLinkCBuild(build): HashLinkCBuild(build);
				},
					retyped: [],
					invalidations: [],
					regenerated: [],
					changedFunctions: [],
					requiresReload: false,
					reloadReasons: [],
					moduleNames: cached.moduleNames,
					nativeTypeDescriptors: cached.nativeTypeDescriptors,
					unchanged: true,
					baseRevision: cached.revision,
					revision: cached.revision,
					metrics: {
						allocationPhases: [],
						elapsedMs: 0.0,
						transactionSnapshotMs: 0.0,
						candidateSetupMs: 0.0,
						frontendMs: 0.0,
						frontendGraphMs: 0.0,
						graphParseMs: 0.0,
						graphDependencyMs: 0.0,
						graphInitializationMs: 0.0,
						frontendTypedFunctions: 0,
						frontendStages: "",
						irPassCosts: [],
						semanticAssemblyMs: 0.0,
						semanticAliasMs: 0.0,
						semanticCanonicalizationMs: 0.0,
						semanticContributionReuseMs: 0.0,
						semanticContributionRebuildMs: 0.0,
						semanticInvalidationMs: 0.0,
						semanticAllocatedBytes: 0.0,
						typingLoweringMs: 0.0,
						analysisMs: 0.0,
						declarationMs: 0.0,
						shapeConnectionMs: 0.0,
						signatureTypingMs: 0.0,
						typerSetupMs: 0.0,
						typerNoReturnMs: 0.0,
						typerMetadataMs: 0.0,
						typerClassBodiesMs: 0.0,
						typerFunctionBodiesMs: 0.0,
						typerGeneratedMs: 0.0,
						bodyTransitionMs: 0.0,
						typerAssemblyMs: 0.0,
						finalizationTransitionMs: 0.0,
						irGenerationMs: 0.0,
						irAssemblyMs: 0.0,
						abiPlanningMs: 0.0,
						backendAssemblyMs: 0.0,
						backendAssemblerCopyMs: 0.0,
						backendCachePreparationMs: 0.0,
						backendLoweringMs: 0.0,
						backendPublicationMs: 0.0,
						backendSnapshotMs: 0.0,
						backendVerificationMs: 0.0,
						backendMetadataMs: 0.0,
						backendFunctionLoweringMs: 0.0,
						backendDebugAssemblyMs: 0.0,
						backendFinalizationMs: 0.0,
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
						patchBytes: 0,
						reuse: "result",
						linkedFunctions: 0,
						movedFunctions: 0
					}};
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

	/** Takes the state a successful build left (see `SessionState.copyForCandidate`). */
	function adoptCandidate(candidate:SessionState):Void {
		state = candidate;
		graph.rebuild(modules);
	}

	function get_modules():Map<String, ModuleState>
		return state.modules;

	function get_semanticWorkspace():SemanticWorkspace
		return state.semanticWorkspace;

	function get_types():TypeRegistry
		return state.types;

	function get_lastTypedProgram():Null<TypedProgram>
		return state.lastTypedProgram;

	function get_inlineCache():compiler.ir.passes.inlining.IrInliner.IrInlineCache
		return state.inlineCache;

	function get_pipelineSnapshot():Null<compiler.compilation.PipelineSnapshot>
		return state.pipelineSnapshot;

	function get_backend():BackendSession
		return state.backend;

	function get_verifyMemo():compiler.ir.verify.IrVerifyMemo
		return state.verifyMemo;

	function identitySalt():String {
		var version = defines.get("compiler-version");
		if (version == null)
			version = compiler.modules.CodeIdentityTable.compilerVersion();
		var lines = [
			for (name => value in defines)
				if (name != "compiler-version") name + "=" + value
		];
		lines.sort(Reflect.compare);
		return "compiler:" + version + "\n" + lines.join("\n");
	}

	/** Select the C ABI used by native-layout queries and source records. */
	public function nativeLayoutTarget():String {
		var configured = defines.get("native-abi-target");
		if (configured != null)
			return configured;
		var interfaceTarget:Null<String> = null;
		for (model in ffi.interfaces()) {
			if (interfaceTarget == null)
				interfaceTarget = model.target;
			else if (interfaceTarget != model.target)
				throw new InternalError('Native layout queries require one HXI target, found "$interfaceTarget" and "${model.target}"');
		}
		if (interfaceTarget != null)
			return interfaceTarget;
		return switch backendTarget {
			case Wasm32 | WasmGc: "portable-abi32";
			case Wasm64: "portable-abi64";
			case HashLink | HashLinkC:
				// A `target` define that names no backend names the C ABI itself.
				var named = defines.get("target");
				named == null || BackendTargets.parse(named) != null ? "portable-abi64" : named;
		}
	}

	/** True when the active target uses one of the experimental WebAssembly backends. */
	public function isWasmTarget():Bool
		return BackendTargets.isWasm(backendTarget);
}
