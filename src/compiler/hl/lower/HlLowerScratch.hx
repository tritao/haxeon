package compiler.hl.lower;

import compiler.hl.HlFunction.HlDebugLocation;
import compiler.hl.HlFunction.HlInstruction;
import compiler.ir.Ir;
import compiler.ir.IrGraph;
import compiler.ir.IrPassScratch.IrNonNullScratch;
import compiler.ir.IrPassScratch.IrValueMarks;

/**
 * The tables `HlLower` fills for each function it lowers, kept from one function to the next so that lowering a program
 * allocates each once, at the size of its largest function. They are indexed by value, block or label id, which are dense
 * within a function. A function's results are copied out at their final length; `release` drops what refers to the
 * function, so none stays reachable from the tables once it is lowered. One function at a time: lowering never nests.
 */
class HlLowerScratch {
	/** The function's graph, shared by the analyses of it. */
	public final graph = new IrGraph();

	public final nonNull = new IrNonNullScratch();

	/** Per value id: its register (-1 before its definition), whether it is a null constant, how many operands read it. */
	public final registers:Array<Int> = [];

	public final nullValues:Array<Bool> = [];
	public final uses:Array<Int> = [];

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
	public final moveDestinations:Array<IrValue> = [];
	public final moveSources:Array<IrValue> = [];

	/** The moves of one edge not written yet, as registers, with the value each defines; and the values written, with where. */
	public final pendingDestinations:Array<Int> = [];

	public final pendingSources:Array<Int> = [];
	public final pendingValues:Array<IrValue> = [];
	public final writtenValues:Array<IrValue> = [];
	public final writtenPositions:Array<Int> = [];

	/** The layout: blocks by id, the walk's marks and stack (block id, next child, end of its children), the order. */
	public final blocksById:Array<Null<IrBlock>> = [];

	public final laidOut = new IrValueMarks();
	public final stackBlocks:Array<Int> = [];
	public final stackNext:Array<Int> = [];
	public final stackEnd:Array<Int> = [];
	public final children:Array<Int> = [];
	public final postorder:Array<IrBlock> = [];
	public final layout:Array<IrBlock> = [];

	/** Per block id, its index in the layout, or -1. */
	public final layoutPositions:Array<Int> = [];

	/** The labels a jump or trap names, and per instruction its index once the others are dropped. */
	public final referencedLabels = new IrValueMarks();

	public final keptPositions:Array<Int> = [];

	public function new() {}

	/** Drops every reference to the function just lowered. */
	public function release():Void {
		graph.release();
		for (index in 0...blocksById.length)
			blocksById[index] = null;
		blocksById.resize(0);
		clearBlocks(postorder);
		clearBlocks(layout);
		clearValues(moveDestinations);
		clearValues(moveSources);
		clearValues(pendingValues);
		clearValues(writtenValues);
	}

	static function clearBlocks(blocks:Array<IrBlock>):Void {
		for (index in 0...blocks.length)
			blocks[index] = null;
		blocks.resize(0);
	}

	static function clearValues(values:Array<IrValue>):Void {
		for (index in 0...values.length)
			values[index] = null;
		values.resize(0);
	}
}
