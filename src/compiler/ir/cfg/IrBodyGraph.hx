package compiler.ir.cfg;

import compiler.core.InternalError;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrPassScratch;

/**
 * `IrGraph` over an `IrBody`: reachable normal and trap-entry edges and immediate dominators, by block id. Its tables are arrays
 * indexed by block id that `reset` refills for another body without giving their storage back, so one graph
 * (`IrPassScratch.bodyGraph`) serves every function of a pass. The walk, and so the order of `order` and of each block's
 * predecessors, is `IrGraph`'s.
 */
class IrBodyGraph {
	/** The reachable blocks in reverse postorder, the entry first. */
	public final order:Array<Int> = [];

	/** Per block id, its index in the body, or -1 for an id no block has. */
	final indices:Array<Int> = [];

	final reachable:Array<Bool> = [];
	final successorStart:Array<Int> = [];
	final successorCounts:Array<Int> = [];
	final successorTargets:Array<Int> = [];
	final predecessorStart:Array<Int> = [];
	final predecessorCounts:Array<Int> = [];
	final predecessorSources:Array<Int> = [];
	final edgeFrom:Array<Int> = [];
	final edgeTo:Array<Int> = [];
	final stack:Array<Int> = [];
	final next:Array<Int> = [];

	/** Immediate dominators by id, -1 for an unreachable block; computed the first time one is asked for. */
	final dominators:Array<Int> = [];

	final rank:Array<Int> = [];

	/** Whether a reachable block begins a try region, so a handler can be entered from inside it. */
	public var hasTry(default, null) = false;

	var hasDominators = false;
	var body:Null<IrBody> = null;

	public function new() {}

	/** The graph of `body`, replacing the one this held. */
	public function reset(body:IrBody):IrBodyGraph {
		this.body = body;
		var count = body.blockCount();
		if (count == 0)
			throw new InternalError("IR function has no entry block");
		var size = 0;
		for (block in 0...count) {
			var id = body.blockId(block);
			if (id < 0)
				throw new InternalError('Negative IR block id $id');
			if (id >= size)
				size = id + 1;
		}
		IrPassScratch.filledInts(indices, size, -1);
		IrPassScratch.filledBools(reachable, size, false);
		IrPassScratch.filledInts(successorStart, size, 0);
		IrPassScratch.filledInts(successorCounts, size, 0);
		IrPassScratch.filledInts(predecessorStart, size, 0);
		IrPassScratch.filledInts(predecessorCounts, size, 0);
		successorTargets.resize(0);
		predecessorSources.resize(0);
		hasDominators = false;
		hasTry = false;
		for (block in 0...count) {
			var id = body.blockId(block);
			if (indices[id] >= 0)
				throw new InternalError('Duplicate IR block $id');
			indices[id] = block;
		}
		order.resize(0);
		visit(body.blockId(0));
		order.reverse();
		return this;
	}

	/** The index in the body of block `id`, which must be one of its blocks. */
	public function indexOf(id:Int):Int {
		var found = id >= 0 && id < indices.length ? indices[id] : -1;
		if (found < 0)
			throw new InternalError('Unknown IR block $id');
		return found;
	}

	public inline function contains(id:Int):Bool
		return id >= 0 && id < indices.length && indices[id] >= 0;

	public inline function isReachable(id:Int):Bool
		return id >= 0 && id < reachable.length && reachable[id];

	public function successorCount(id:Int):Int {
		if (!isReachable(id))
			throw new InternalError('IR block $id is not reachable');
		return successorCounts[id];
	}

	public inline function successor(id:Int, index:Int):Int
		return successorTargets[successorStart[id] + index];

	public inline function predecessorCount(id:Int):Int
		return id >= 0 && id < predecessorCounts.length ? predecessorCounts[id] : 0;

	public inline function predecessor(id:Int, index:Int):Int
		return predecessorSources[predecessorStart[id] + index];

	/** The immediate dominator of `id`, the entry for itself, or -1 when `id` is not reachable. */
	public function immediateDominator(id:Int):Int {
		if (!hasDominators) {
			computeDominators();
			hasDominators = true;
		}
		return id >= 0 && id < dominators.length ? dominators[id] : -1;
	}

	public function dominates(definition:Int, use:Int):Bool {
		if (!isReachable(use))
			return false;
		while (use != definition) {
			var parent = immediateDominator(use);
			if (parent == use)
				return false;
			use = parent;
		}
		return true;
	}

	/** As `IrGraph.computeDominators`. */
	function computeDominators():Void {
		var size = indices.length,
			table = IrPassScratch.filledInts(dominators, size, -1),
			rank = IrPassScratch.filledInts(this.rank, size, -1);
		for (index in 0...order.length)
			rank[order[index]] = index;
		table[order[0]] = order[0];
		var changed = true;
		while (changed) {
			changed = false;
			for (index in 1...order.length) {
				var id = order[index], parent = -1;
				for (index in 0...predecessorCount(id)) {
					var pred = predecessor(id, index);
					if (table[pred] >= 0)
						parent = parent < 0 ? pred : intersect(table, rank, parent, pred);
				}
				if (parent >= 0 && table[id] != parent) {
					table[id] = parent;
					changed = true;
				}
			}
		}
	}

	static function intersect(table:Array<Int>, rank:Array<Int>, left:Int, right:Int):Int {
		while (left != right) {
			while (rank[left] > rank[right])
				left = table[left];
			while (rank[right] > rank[left])
				right = table[right];
		}
		return left;
	}

	function visit(entry:Int):Void {
		edgeFrom.resize(0);
		edgeTo.resize(0);
		stack.resize(0);
		next.resize(0);
		prepareVisit(entry);
		stack.push(entry);
		next.push(0);
		while (stack.length > 0) {
			var top = stack.length - 1, id = stack[top];
			if (next[top] < successorCounts[id]) {
				var target = successor(id, next[top]);
				next[top]++;
				edgeFrom.push(id);
				edgeTo.push(target);
				predecessorCounts[target]++;
				if (!reachable[target]) {
					prepareVisit(target);
					stack.push(target);
					next.push(0);
				}
			} else {
				order.push(id);
				stack.pop();
				next.pop();
			}
		}
		var offset = 0;
		for (id in 0...predecessorCounts.length) {
			predecessorStart[id] = offset;
			offset += predecessorCounts[id];
			predecessorCounts[id] = 0;
		}
		predecessorSources.resize(offset);
		for (edge in 0...edgeFrom.length) {
			var target = edgeTo[edge];
			predecessorSources[predecessorStart[target] + predecessorCounts[target]] = edgeFrom[edge];
			predecessorCounts[target]++;
		}
	}

	/** As `IrGraph.prepareVisit`: the terminator's distinct targets, then the handler of each try region begun in the block. */
	function prepareVisit(id:Int):Void {
		var body = this.body, block = indexOf(id);
		reachable[id] = true;
		var terminator = body.terminatorRow(block);
		if (terminator < 0)
			throw new InternalError('Reachable IR block $id has no terminator');
		var start = successorTargets.length;
		successorStart[id] = start;
		switch body.opcode(terminator) {
			case IrOpcode.Jump:
				successorTargets.push(body.aux(terminator));
			case IrOpcode.Branch:
				var yes = body.auxInt(terminator, 0), no = body.auxInt(terminator, 1);
				successorTargets.push(yes);
				if (yes != no)
					successorTargets.push(no);
			case IrOpcode.Switch:
				// IrSwitch.successors: the targets in order, each once, then the otherwise unless it is one of them.
				var count = body.auxInt(terminator, 1);
				for (index in 0...count)
					pushOnce(body.auxInt(terminator, 2 + index), start);
				pushOnce(body.auxInt(terminator, 0), start);
			default:
		}
		var row = body.firstRow(block);
		while (row != terminator) {
			if (body.opcode(row) == IrOpcode.BeginTry) {
				hasTry = true;
				var handler = body.auxInt(row, 0), after = body.auxInt(row, 1);
				if (!contains(after))
					throw new InternalError('Unknown IR block $after');
				pushOnce(handler, start);
			}
			row = body.nextRow(row);
		}
		for (index in start...successorTargets.length)
			if (!contains(successorTargets[index]))
				throw new InternalError('Unknown IR block ${successorTargets[index]}');
		successorCounts[id] = successorTargets.length - start;
	}

	function pushOnce(target:Int, start:Int):Void {
		for (index in start...successorTargets.length)
			if (successorTargets[index] == target)
				return;
		successorTargets.push(target);
	}
}
