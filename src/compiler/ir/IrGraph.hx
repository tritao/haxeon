package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;
import haxe.ds.ReadOnlyArray;

/**
 * Reachable normal and trap-entry edges of one function, with immediate dominators.
 *
 * Block ids are small within a function (the IR hands them out from one past the largest), so every table here is an array
 * indexed by id, sized once from the largest id: lookups neither hash nor box.
 */
class IrGraph {
	static final noBlocks:ReadOnlyArray<Int> = ([]:Array<Int>);

	/** The reachable blocks in reverse postorder, the entry first. */
	public final order:ReadOnlyArray<Int>;

	final blocks:Array<Null<IrBlock>>;
	final successors:Array<Null<Array<Int>>>;
	final predecessors:Array<Null<Array<Int>>>;
	final reachable:Array<Bool>;

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
		var blockTable:Array<Null<IrBlock>> = [],
			successorTable:Array<Null<Array<Int>>> = [],
			predecessorTable:Array<Null<Array<Int>>> = [],
			reachableTable:Array<Bool> = [];
		blockTable.resize(size);
		successorTable.resize(size);
		predecessorTable.resize(size);
		reachableTable.resize(size);
		for (index in 0...size) {
			blockTable[index] = null;
			successorTable[index] = null;
			predecessorTable[index] = null;
			reachableTable[index] = false;
		}
		blocks = blockTable;
		successors = successorTable;
		predecessors = predecessorTable;
		reachable = reachableTable;
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

	/** The blocks `id` can go to next, normal and trap-entry edges; `id` must be reachable. */
	public function successorsOf(id:Int):ReadOnlyArray<Int> {
		var found = id >= 0 && id < successors.length ? successors[id] : null;
		if (found == null)
			throw new InternalError('IR block $id is not reachable');
		return found;
	}

	/** The reachable blocks that go to `id`, in the order the walk met them; empty for the entry and unreachable blocks. */
	public function predecessorsOf(id:Int):ReadOnlyArray<Int> {
		var found = id >= 0 && id < predecessors.length ? predecessors[id] : null;
		return found == null ? noBlocks : found;
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

	/** Depth first from `entry`, recording each reachable block's edges and pushing it to `postorder` once it is done. */
	function visit(entry:Int, postorder:Array<Int>):Void {
		prepareVisit(entry);
		var stack:Array<Int> = [entry], next:Array<Int> = [0];
		while (stack.length > 0) {
			var top = stack.length - 1, id = stack[top], edges = successorsOf(id);
			if (next[top] < edges.length) {
				var target = edges[next[top]];
				next[top]++;
				var into = predecessors[target];
				if (into == null) {
					into = [];
					predecessors[target] = into;
				}
				into.push(id);
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
	}

	function prepareVisit(id:Int):Void {
		var block = this.block(id);
		reachable[id] = true;
		var next:Array<Int> = [];
		var terminator = block.terminator;
		if (terminator == null)
			throw new InternalError('Reachable IR block $id has no terminator');
		switch terminator.value {
			case Jump(target):
				next.push(target);
			case Branch(_, yes, no):
				next.push(yes);
				if (yes != no)
					next.push(no);
			case Switch(_, targets, otherwise):
				for (target in IrSwitch.successors(targets, otherwise))
					next.push(target);
			case Return(_), Throw(_), Rethrow(_), Unreachable:
		}
		for (instruction in block.instructions)
			switch instruction.value {
				case BeginTry(handler, after, _):
					if (!contains(after))
						throw new InternalError('Unknown IR block $after');
					if (next.indexOf(handler) < 0)
						next.push(handler);
				default:
			}
		for (target in next)
			if (!contains(target))
				throw new InternalError('Unknown IR block $target');
		successors[id] = next;
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
				for (pred in predecessorsOf(id))
					if (table[pred] >= 0)
						parent = parent < 0 ? pred : intersect(table, rank, parent, pred);
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
