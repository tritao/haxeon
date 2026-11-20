package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;
import haxe.ds.ReadOnlyArray;

/**
 * Reachable normal and trap-entry edges of one function, with immediate dominators.
 *
 * Block ids are small within a function (the IR hands them out from one past the largest), so every table here is an array
 * indexed by id, sized once from the largest id: lookups neither hash nor box. The edges of all blocks are in two flat arrays,
 * one of successors and one of predecessors, each block's a run of them (`successorCount`, `successor`), so a graph is a
 * handful of arrays whatever the number of blocks.
 */
class IrGraph {
	/** The reachable blocks in reverse postorder, the entry first. */
	public final order:ReadOnlyArray<Int>;

	final blocks:Array<Null<IrBlock>>;
	final reachable:Array<Bool>;

	/** Per block id, where its run starts in `successorTargets` and how long it is (0 for an unreachable block). */
	final successorStart:Array<Int>;

	final successorCounts:Array<Int>;
	final successorTargets:Array<Int> = [];

	/** The same for predecessors, each block's in the order the walk met them. */
	final predecessorStart:Array<Int>;

	final predecessorCounts:Array<Int>;
	final predecessorSources:Array<Int> = [];

	/** Immediate dominators by id, -1 for an unreachable block; computed the first time one is asked for. */
	var dominators:Null<Array<Int>> = null;

	public function new(fn:IrFunction) {
		if (fn.blocks.length == 0)
			throw new InternalError("IR function has no entry block");
		var size = 0;
		for (block in fn.blocks) {
			if (block.id < 0)
				throw new InternalError('Negative IR block id ${block.id}');
			if (block.id >= size)
				size = block.id + 1;
		}
		blocks = [];
		blocks.resize(size);
		reachable = [];
		reachable.resize(size);
		for (index in 0...size) {
			blocks[index] = null;
			reachable[index] = false;
		}
		successorStart = filled(size, 0);
		successorCounts = filled(size, 0);
		predecessorStart = filled(size, 0);
		predecessorCounts = filled(size, 0);
		for (block in fn.blocks) {
			if (blocks[block.id] != null)
				throw new InternalError('Duplicate IR block ${block.id}');
			blocks[block.id] = block;
		}
		var postorder:Array<Int> = [];
		visit(fn.blocks[0].id, postorder);
		postorder.reverse();
		order = postorder;
	}

	static function filled(count:Int, value:Int):Array<Int> {
		var values:Array<Int> = [];
		values.resize(count);
		for (index in 0...count)
			values[index] = value;
		return values;
	}

	/** The block `id`; it must be one of the function's blocks. */
	public function block(id:Int):IrBlock {
		var found = id >= 0 && id < blocks.length ? blocks[id] : null;
		if (found == null)
			throw new InternalError('Unknown IR block $id');
		return found;
	}

	/** Whether `id` is one of the function's blocks, reachable or not. */
	public function contains(id:Int):Bool
		return id >= 0 && id < blocks.length && blocks[id] != null;

	/** Whether `id` is reached from the entry. */
	public function isReachable(id:Int):Bool
		return id >= 0 && id < reachable.length && reachable[id];

	/** How many blocks `id` can go to next, normal and trap-entry edges; `id` must be reachable. */
	public function successorCount(id:Int):Int {
		if (!isReachable(id))
			throw new InternalError('IR block $id is not reachable');
		return successorCounts[id];
	}

	/** The `index`th block `id` can go to next. */
	public inline function successor(id:Int, index:Int):Int
		return successorTargets[successorStart[id] + index];

	/** How many reachable blocks go to `id`: none for the entry and unreachable blocks. */
	public function predecessorCount(id:Int):Int
		return id >= 0 && id < predecessorCounts.length ? predecessorCounts[id] : 0;

	/** The `index`th reachable block that goes to `id`, in the order the walk met them. */
	public inline function predecessor(id:Int, index:Int):Int
		return predecessorSources[predecessorStart[id] + index];

	/** Whether `from` goes to `to`. */
	public function hasEdge(from:Int, to:Int):Bool {
		if (!isReachable(from))
			return false;
		for (index in 0...successorCounts[from])
			if (successor(from, index) == to)
				return true;
		return false;
	}

	/** The immediate dominator of `id`, the entry for itself, or -1 when `id` is not reachable. */
	public function immediateDominator(id:Int):Int {
		var table = dominators;
		if (table == null) {
			table = computeDominators();
			dominators = table;
		}
		return id >= 0 && id < table.length ? table[id] : -1;
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

	/**
	 * Depth first from `entry`, recording each reachable block's successors and pushing it to `postorder` once it is done; the
	 * edges, in the order the walk takes them, then give each block its predecessors in that order.
	 */
	function visit(entry:Int, postorder:Array<Int>):Void {
		var edgeFrom:Array<Int> = [], edgeTo:Array<Int> = [];
		prepareVisit(entry);
		var stack:Array<Int> = [entry], next:Array<Int> = [0];
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
				postorder.push(id);
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

	/** Marks `id` reachable and appends its successors, each once, as its run. */
	function prepareVisit(id:Int):Void {
		var block = this.block(id);
		reachable[id] = true;
		var terminator = block.terminator;
		if (terminator == null)
			throw new InternalError('Reachable IR block $id has no terminator');
		var start = successorTargets.length;
		successorStart[id] = start;
		switch terminator.value {
			case Jump(target):
				successorTargets.push(target);
			case Branch(_, yes, no):
				successorTargets.push(yes);
				if (yes != no)
					successorTargets.push(no);
			case Switch(_, targets, otherwise):
				for (target in IrSwitch.successors(targets, otherwise))
					successorTargets.push(target);
			case Return(_), Throw(_), Rethrow(_), Unreachable:
		}
		for (instruction in block.instructions)
			switch instruction.value {
				case BeginTry(handler, after, _):
					if (!contains(after))
						throw new InternalError('Unknown IR block $after');
					var known = false;
					for (index in start...successorTargets.length)
						if (successorTargets[index] == handler)
							known = true;
					if (!known)
						successorTargets.push(handler);
				default:
			}
		for (index in start...successorTargets.length)
			if (!contains(successorTargets[index]))
				throw new InternalError('Unknown IR block ${successorTargets[index]}');
		successorCounts[id] = successorTargets.length - start;
	}

	/** Immediate dominators by the iterative algorithm of Cooper, Harvey and Kennedy, over reverse postorder ranks. */
	function computeDominators():Array<Int> {
		var table:Array<Int> = [], rank:Array<Int> = [];
		table.resize(blocks.length);
		rank.resize(blocks.length);
		for (index in 0...blocks.length) {
			table[index] = -1;
			rank[index] = -1;
		}
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
		return table;
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
}
