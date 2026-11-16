package compiler.compilation;

import compiler.abi.PatchPlanner.AbiChange;
import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;
import compiler.core.AllocationMeter.PhaseAllocation;
import compiler.core.CancellationToken;
import compiler.hl.incremental.HlModuleAssembler;
import compiler.hl.incremental.HlModuleAssembler.HlAssemblyResult;
import compiler.ir.Ir.IrProgram;
import haxe.io.Bytes;

/** What a backend made of one build's IR. */
typedef BackendAssemblyResult = {
	final assembly:HlAssemblyResult;

	/** The assembler the build left (HashLink); a reused result gives it back to the session. */
	final assembler:HlModuleAssembler;

	final abi:RuntimeAbiDescriptor;
	final reloadReasons:Array<AbiChange>;
	final patchBytes:Null<Bytes>;
	final abiPlanningDoneAt:Float;
	final backendAssemblyDoneAt:Float;
	final patchEncodingDoneAt:Float;
	final assemblerCopyMs:Float;
	final snapshotAttachmentMs:Float;
	final allocationPhases:Array<PhaseAllocation>;
}

/**
 * The backend of a compilation session: what turns a build's final IR into the target's artifact, and the state it keeps from
 * one build to the next. The compiler owns one (`Compiler.backend`). A build works on the candidate's copy (`forCandidate`) and
 * the compiler adopts it with the rest of the candidate, so a failed or rejected build leaves the session's backend as it was.
 */
interface BackendSession {
	/** This session when it is the HashLink one (live patching and its persisted identity are HashLink's), or null. */
	function hashLink():Null<HashLinkBackendSession>;

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
