package compiler.ir;

import compiler.ir.Ir;

/** Reachable normal and trap-entry edges, with immediate dominators. */
class IrGraph {
	public final blocks:Map<Int, IrBlock> = [];
	public final predecessors:Map<Int, Array<Int>> = [];
	public final successors:Map<Int, Array<Int>> = [];
	public final order:Array<Int> = [];
	public final immediate:Map<Int, Int> = [];

	final rank:Map<Int, Int> = [];

	public function new(fn:IrFunction) {
		if (fn.blocks.length == 0)
			throw "IR function has no entry block";
		for (block in fn.blocks) {
			if (blocks.exists(block.id))
				throw 'Duplicate IR block ${block.id}';
			blocks.set(block.id, block);
		}
		visit(fn.blocks[0].id, []);
		order.reverse();
		for (i in 0...order.length)
			rank.set(order[i], i);
		immediate.set(order[0], order[0]);
		var changed = true;
		while (changed) {
			changed = false;
			for (i in 1...order.length) {
				var id = order[i], parent:Null<Int> = null;
				for (pred in predecessors.get(id))
					if (immediate.exists(pred))
						parent = parent == null ? pred : intersect(parent, pred);
				if (parent != null && (!immediate.exists(id) || immediate.get(id) != parent)) {
					immediate.set(id, parent);
					changed = true;
				}
			}
		}
	}

	public function block(id:Int):IrBlock {
		if (!blocks.exists(id))
			throw 'Unknown IR block $id';
		return blocks.get(id);
	}

	function visit(id:Int, seen:Map<Int, Bool>):Void {
		if (seen.exists(id))
			return;
		if (!blocks.exists(id))
			throw 'Unknown IR block $id';
		seen.set(id, true);
		var block = blocks.get(id), next:Array<Int> = [];
		if (block.terminator == null)
			throw 'Reachable IR block $id has no terminator';
		switch block.terminator.value {
			case Jump(target):
				next.push(target);
			case Branch(_, yes, no):
				next.push(yes);
				if (yes != no)
					next.push(no);
			case Return(_), Throw(_), Rethrow(_):
		}
		for (instruction in block.instructions)
			switch instruction.value {
				case BeginTry(handler, after):
					if (!blocks.exists(after))
						throw 'Unknown IR block $after';
					if (next.indexOf(handler) < 0)
						next.push(handler);
				default:
			}
		successors.set(id, next);
		for (target in next) {
			if (!predecessors.exists(target))
				predecessors.set(target, []);
			predecessors.get(target).push(id);
			visit(target, seen);
		}
		order.push(id);
	}

	function intersect(left:Int, right:Int):Int {
		while (left != right) {
			while (requiredInt(rank, left) > requiredInt(rank, right))
				left = requiredInt(immediate, left);
			while (requiredInt(rank, right) > requiredInt(rank, left))
				right = requiredInt(immediate, right);
		}
		return left;
	}

	static function requiredInt(values:Map<Int, Int>, key:Int):Int {
		if (!values.exists(key))
			throw 'Missing graph index $key';
		return values.get(key);
	}

	public function dominates(definition:Int, use:Int):Bool {
		if (!immediate.exists(use))
			return false;
		while (use != definition) {
			var parent = requiredInt(immediate, use);
			if (parent == use)
				return false;
			use = parent;
		}
		return true;
	}
}
