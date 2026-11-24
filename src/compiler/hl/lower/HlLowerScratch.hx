package compiler.hl.lower;

import compiler.hl.HlFunction.HlDebugAssignment;
import compiler.hl.HlFunction.HlDebugLocation;
import compiler.hl.HlFunction.HlInstruction;
import compiler.ir.analysis.IrExactTypeFacts;
import compiler.ir.cfg.IrBodyGraph;
import compiler.ir.cfg.PhiEdges;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrPassScratch.IrNonNullScratch;
import compiler.ir.model.IrPassScratch.IrValueMarks;
import compiler.ir.model.IrTypeIds;

/**
 * The tables `HlLower` fills for each function it lowers, kept from one function to the next so that lowering a program
 * allocates each once, at the size of its largest function. They are indexed by value, block, binding or label id, which are
 * dense within a function's body. A function's results are copied out at their final length; `release` drops what refers to the
 * function, so none stays reachable from the tables once it is lowered. One function at a time: lowering never nests.
 */
@:nullSafety(Strict)
class HlLowerScratch {
	/** The function's graph, shared by the analyses of it, and the analyses. */
	public final graph = new IrBodyGraph();

	public final nonNull = new IrNonNullScratch();
	public final exactTypes = new IrExactTypeFacts();
	public final scalarLocals = new HlScalarValueLocals();

	/** The edge blocks lowering gives a body, and the builder of the copies they are added to. */
	public final phiEdges = new PhiEdges();

	public final bodyBuilder = new IrBodyBuilder(new IrTypeIds());

	/** Per value id: its register (-1 before its definition), whether it is a null constant, how many operands read it. */
	public final registers:Array<Int> = [];

	public final nullValues:Array<Bool> = [];
	public final uses:Array<Int> = [];

	/** Per value id: the array a cast of its box gives back (-1 for none); the boxes of those arrays, never made. */
	public final arrayRecasts:Array<Int> = [];

	public final unboxedArrays = new IrValueMarks();

	/** Per pointer offset folded into memory accesses: its pointer and byte offset (-1 when not folded), and its address uses. */
	public final foldedPointers:Array<Int> = [];

	public final foldedOffsets:Array<Int> = [];
	public final addressUses:Array<Int> = [];

	/** Per block id, the value its `Catch` defines, or -1. */
	public final catchValues:Array<Int> = [];

	/** Per value id its first debug binding, per binding the next one for the same value (-1 after the last). */
	public final firstBinding:Array<Int> = [];

	public final nextBinding:Array<Int> = [];

	/** The debug assignments made, with the binding of each; per binding, where its scope's last location is (-2 until found). */
	public final debugAssignments:Array<HlDebugAssignment> = [];

	public final assignmentBindings:Array<Int> = [];
	public final scopeEnds:Array<Int> = [];

	/** A switch's stubs: the label of each and the block it jumps to. */
	public final stubLabels:Array<Int> = [];

	public final stubTargets:Array<Int> = [];

	/** The type of each register, as the function is lowered. */
	public final registerTypes:Array<Int> = [];

	/** The function's instructions and their debug locations. */
	public final instructions:Array<HlInstruction> = [];

	public final debugLocations:Array<HlDebugLocation> = [];
	public final registerAllocation = new HlRegisterAllocation();

	/**
	 * The phi moves of each edge, grouped by the block the edge leaves (only a jump's edge has any): per block id, where its run
	 * starts in `moveDestinations`/`moveSources`, how long it is, and the block it goes to.
	 */
	public final moveStart:Array<Int> = [];

	public final moveCount:Array<Int> = [];
	public final moveTarget:Array<Int> = [];
	public final moveDestinations:Array<Int> = [];
	public final moveSources:Array<Int> = [];

	/** The moves of one edge not written yet, as registers, with the value each defines; and the values written, with where. */
	public final pendingDestinations:Array<Int> = [];

	public final pendingSources:Array<Int> = [];
	public final pendingValues:Array<Int> = [];
	public final writtenValues:Array<Int> = [];
	public final writtenPositions:Array<Int> = [];

	/** The layout: block indices by id (-1 for none), the walk's marks and stack (block id, next child, end of its children), the order. */
	public final blocksById:Array<Int> = [];

	public final laidOut = new IrValueMarks();
	public final stackBlocks:Array<Int> = [];
	public final stackNext:Array<Int> = [];
	public final stackEnd:Array<Int> = [];
	public final children:Array<Int> = [];
	public final postorder:Array<Int> = [];
	public final layout:Array<Int> = [];

	/** Per block id, its index in the layout, or -1. */
	public final layoutPositions:Array<Int> = [];

	/** The labels a jump or trap names, and per instruction its index once the others are dropped. */
	public final referencedLabels = new IrValueMarks();

	public final keptPositions:Array<Int> = [];

	public function new() {}

	/** Drops what refers to the function just lowered. */
	public function release():Void {
		scalarLocals.release();
		phiEdges.release();
		debugAssignments.resize(0);
	}
}
