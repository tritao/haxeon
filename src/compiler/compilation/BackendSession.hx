package compiler.compilation;

import compiler.abi.PatchPlanner.AbiChange;
import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;
import compiler.backend.Backend.BackendTarget;
import compiler.core.AllocationMeter.PhaseAllocation;
import compiler.core.CancellationToken;
import compiler.hl.incremental.HlModuleAssembler;
import compiler.ir.Ir.IrProgram;

/** What a backend made of one build's IR. */
typedef BackendAssemblyResult = {
	final artifact:BackendArtifact;

	/** The assembler the build left (HashLink; null for another backend); a reused result gives it back to the session. */
	final assembler:Null<HlModuleAssembler>;

	final abi:RuntimeAbiDescriptor;
	final reloadReasons:Array<AbiChange>;

	/** The function slots a patch replaces. */
	final changedFunctions:Array<Int>;

	final requiresReload:Bool;

	/** The artifact is the one the running module already has. */
	final unchanged:Bool;

	final baseRevision:Int;
	final revision:Int;
	final moduleFunctions:Int;
	final moduleNatives:Int;

	/** Functions taken from the last plain build's lowering, and how many of them were re-indexed (see `HlLoweredCache`). */
	final linkedFunctions:Int;

	final movedFunctions:Int;
	final timings:BackendTimings;
	final abiPlanningDoneAt:Float;
	final backendAssemblyDoneAt:Float;
	final patchEncodingDoneAt:Float;
	final assemblerCopyMs:Float;
	final snapshotAttachmentMs:Float;
	final allocationPhases:Array<PhaseAllocation>;
}

/** Where a backend's assembly spent its time (ms), for `CompileMetrics`. */
typedef BackendTimings = {
	final cachePreparationMs:Float;
	final loweringMs:Float;
	final publicationMs:Float;
	final verificationMs:Float;
	final metadataMs:Float;
	final functionLoweringMs:Float;
	final debugAssemblyMs:Float;
	final lowerFinalizationMs:Float;
}

/**
 * The backend of a compilation session: what turns a build's final IR into the target's artifact, and the state it keeps from
 * one build to the next. The compiler owns one (`Compiler.backend`). A build works on the candidate's copy (`forCandidate`) and
 * the compiler adopts it with the rest of the candidate, so a failed or rejected build leaves the session's backend as it was.
 */
interface BackendSession {
	/** The target this session builds for. */
	function backendTarget():BackendTarget;

	/** This session when it is the HashLink one (live patching and its persisted identity are HashLink's), or null. */
	function hashLink():Null<HashLinkBackendSession>;

	/** This session when it is the Wasm one (its patch state and module cache), or null. */
	function wasm():Null<WasmBackendSession>;

	/** The session a candidate build works on. */
	function forCandidate():BackendSession;

	/** What assembly reads besides the IR: equal keys and an equal IR give the same artifact (see `PipelineSnapshot`). */
	function environmentKey(context:CompilationContext):String;

	function assemble(context:CompilationContext, ir:IrProgram, regenerated:Array<String>, relocated:Array<String>,
			token:Null<CancellationToken>):BackendAssemblyResult;

	/** An earlier result for this build: the artifact and the state it left stay, the timings are this build's (none). */
	function reuse(previous:BackendAssemblyResult, at:Float):BackendAssemblyResult;

	/** Why an artifact made from the same inputs differs from `previous`, or null when it is the same artifact. */
	function difference(previous:BackendAssemblyResult, fresh:BackendAssemblyResult):Null<String>;
}
