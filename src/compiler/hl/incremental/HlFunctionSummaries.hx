package compiler.hl.incremental;

import compiler.ir.analysis.IrReachability.IrBodyEdges;
import compiler.ir.analysis.IrReachability.IrTrimSummary;
import compiler.ir.model.Ir.IrNative;
import compiler.ir.reuse.IrFunctionMemo;

/**
 * What the whole-program steps around HashLink lowering work out from each function alone, kept while the function is the same
 * object (`IrFunctionMemo`), so a build scans only the functions an edit made. The session keeps one with the lowered functions
 * (`HlLoweredCache`), which the copies share.
 */
class HlFunctionSummaries {
	/** The signature text of each function, for the runtime ABI (`RuntimeAbi.describe`). */
	public final abiSignatures = new IrFunctionMemo<String>();

	/** What each function's body calls, makes and mentions, for a plain build's reachability walk (`IrReachabilityWalk`). */
	public final walk = new IrFunctionMemo<IrBodyEdges>();

	/** The globals and classes each function names, for a plain build's tables (`IrReachability.trimTables`). */
	public final trim = new IrFunctionMemo<IrTrimSummary>();

	/** The enums each function may need boxed descriptors of (`IrEnumRuntimeTypes.declarations`). */
	public final enumUses = new IrFunctionMemo<Array<String>>();

	/** The runtime natives each function's rows call (`HlLower.discoverRuntimeNatives`). */
	public final natives = new IrFunctionMemo<Array<IrNative>>();

	public function new() {}

	/** Drops what the build that just ended did not ask for. */
	public function endBuild():Void {
		abiSignatures.endBuild();
		walk.endBuild();
		trim.endBuild();
		enumUses.endBuild();
		natives.endBuild();
	}
}
