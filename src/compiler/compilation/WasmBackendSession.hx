package compiler.compilation;

import compiler.abi.RuntimeAbi;
import compiler.backend.Backend.BackendOptions;
import compiler.backend.Backend.BackendTarget;
import compiler.backend.wasm.WasmBackend;
import compiler.backend.wasm.WasmPatch.WasmPatchArtifact;
import compiler.backend.wasm.WasmPatch.WasmPatchState;
import compiler.compilation.BackendArtifact;
import compiler.compilation.BackendSession.BackendAssemblyResult;
import compiler.compilation.BackendSession.BackendTimings;
import compiler.core.AllocationMeter;
import compiler.core.CancellationToken;
import compiler.core.InternalError;
import compiler.ir.model.Ir.IrProgram;
import haxe.Json;
import haxe.io.Bytes;

/** The module a Wasm session built last, with the program and the options it was built from. */
typedef WasmEncodedModule = {
	final ir:IrProgram;
	final options:String;
	final bytes:Bytes;
}

/**
 * The Wasm backend of a compilation session (`wasm32`, `wasm-gc`). A build runs the Wasm backend on the final IR and nothing of
 * HashLink's. The session keeps the module it built last, so a build whose IR and options are the ones that module was built from
 * (a build that reused its IR) gets the same bytes without building them again, and the state of the live module a Wasm patch is
 * checked against (`patchBase`, `patch`). Both follow the candidate: a failed build leaves them as they were.
 *
 * A Wasm module is not patched into a running host, so a build has no revision history: each build is revision 1 of a fresh
 * module, as a plain HashLink build is. Unifying Wasm patch identities with HashLink's stable function ids is a later step.
 */
class WasmBackendSession implements BackendSession {
	final target:BackendTarget;
	var encoded:Null<WasmEncodedModule>;

	/** The live module's identities a replacement must keep (`WasmBackend.compilePatchBase`); null until a base is built. */
	public var patchState(default, null):Null<WasmPatchState>;

	public function new(target:BackendTarget, ?encoded:WasmEncodedModule, ?patchState:WasmPatchState) {
		this.target = target;
		this.encoded = encoded;
		this.patchState = patchState;
	}

	public function backendTarget():BackendTarget
		return target;

	public function hashLink():Null<HashLinkBackendSession>
		return null;

	public function wasm():Null<WasmBackendSession>
		return this;

	public function forCandidate():BackendSession
		return new WasmBackendSession(target, encoded, patchState);

	/** The options a build runs the backend with: the request's (`Compiler.backendOptions`), or the defaults for the target. */
	public function options(context:CompilationContext):BackendOptions {
		var requested = context.backendOptions;
		if (requested != null) {
			if (requested.target != target)
				throw new InternalError('Wasm session for ${Std.string(target)} was given options for ${Std.string(requested.target)}');
			return requested;
		}
		return {target: target, debugNames: true, developmentMetadata: context.developmentMetadata};
	}

	public function environmentKey(context:CompilationContext):String
		return "wasm:" + Json.stringify(options(context));

	public function assemble(context:CompilationContext, ir:IrProgram, regenerated:Array<String>,
			relocated:Array<String>,
			token:Null<CancellationToken>):BackendAssemblyResult {
		var allocationAtStart = AllocationMeter.sample();
		compiler.ir.analysis.IrReachabilityReport.report("final program", ir);
		var abi = RuntimeAbi.describe(ir), abiPlanningDoneAt = Sys.time() * 1000.0;
		var allocationAfterAbi = AllocationMeter.sample();
		var chosen = options(context), key = Json.stringify(chosen), last = encoded, known = last;
		if (known == null || known.ir != ir || known.options != key) {
			known = {ir: ir, options: key, bytes: new WasmBackend().compile(ir, chosen).bytes};
			encoded = known;
		}
		// Unchanged: the module is the bytes of the one this session built last.
		var unchanged = last != null && (last == known || last.bytes.compare(known.bytes) == 0);
		var builtAt = Sys.time() * 1000.0;
		if (token != null)
			token.check();
		return {
			artifact: WasmBuild({bytes: known.bytes}),
			assembler: null,
			abi: abi,
			reloadReasons: [],
			changedFunctions: [],
			requiresReload: false,
			unchanged: unchanged,
			baseRevision: 0,
			revision: 1,
			moduleFunctions: ir.functions.length,
			moduleNatives: ir.natives.length,
			linkedFunctions: 0,
			movedFunctions: 0,
			timings: noTimings,
			abiPlanningDoneAt: abiPlanningDoneAt,
			backendAssemblyDoneAt: builtAt,
			patchEncodingDoneAt: builtAt,
			assemblerCopyMs: 0.0,
			snapshotAttachmentMs: 0.0,
			allocationPhases: [
				AllocationMeter.delta("abi", allocationAtStart, allocationAfterAbi),
				AllocationMeter.delta("wasm-module", allocationAfterAbi, AllocationMeter.sample())
			]
		};
	}

	/** The last build's result for a build with its inputs: the module is the one this session built last, so it is unchanged. */
	public function reuse(previous:BackendAssemblyResult, at:Float):BackendAssemblyResult
		return {
			artifact: previous.artifact,
			assembler: null,
			abi: previous.abi,
			reloadReasons: previous.reloadReasons,
			changedFunctions: previous.changedFunctions,
			requiresReload: previous.requiresReload,
			unchanged: true,
			baseRevision: previous.baseRevision,
			revision: previous.revision,
			moduleFunctions: previous.moduleFunctions,
			moduleNatives: previous.moduleNatives,
			linkedFunctions: 0,
			movedFunctions: 0,
			timings: noTimings,
			abiPlanningDoneAt: at,
			backendAssemblyDoneAt: at,
			patchEncodingDoneAt: at,
			assemblerCopyMs: 0.0,
			snapshotAttachmentMs: 0.0,
			allocationPhases: []
		};

	public function difference(previous:BackendAssemblyResult, fresh:BackendAssemblyResult):Null<String> {
		var left = BackendArtifacts.wasm(previous.artifact).bytes, right = BackendArtifacts.wasm(fresh.artifact).bytes;
		if (left.compare(right) == 0)
			return null;
		return left.length != right.length
			? "module size " + left.length + " -> " + right.length : "module bytes differ";
	}

	/**
	 * Builds `program` as the base of a live Wasm module and keeps its patch state; `patch` checks replacements against it. The
	 * options are those of `options` with development metadata, as for every patch module.
	 */
	public function patchBase(program:IrProgram, options:BackendOptions):WasmPatchArtifact {
		var artifact = new WasmBackend().compilePatchBase(program, options);
		patchState = artifact.state;
		return artifact;
	}

	/** A replacement for the functions in `changed`, checked against the live module's state, which it then becomes. */
	public function patch(program:IrProgram, changed:Array<String>, options:BackendOptions):WasmPatchArtifact {
		var state = patchState;
		if (state == null)
			throw new InternalError("A Wasm patch needs a live base module (patchBase)");
		var artifact = new WasmBackend().compilePatch(state, program, changed, options);
		patchState = artifact.state;
		return artifact;
	}

	static final noTimings:BackendTimings = {
		cachePreparationMs: 0.0,
		loweringMs: 0.0,
		publicationMs: 0.0,
		verificationMs: 0.0,
		metadataMs: 0.0,
		functionLoweringMs: 0.0,
		debugAssemblyMs: 0.0,
		lowerFinalizationMs: 0.0
	};
}
