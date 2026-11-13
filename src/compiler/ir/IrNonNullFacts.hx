package compiler.ir;

import compiler.ir.Ir;

/** Dense bits for the function's SSA identities; each set shares the immutable identity index. */
private class NonNullFactSet {
	final positions:Map<Int, Int>;
	final words:Array<Int>;

	public function new(positions:Map<Int, Int>, words:Array<Int>) {
		this.positions = positions;
		this.words = words;
	}

	public function copy():NonNullFactSet
		return new NonNullFactSet(positions, words.copy());

	public function exists(value:Int):Bool {
		var index = positions.get(value);
		return index != null && (words[index >>> 5] & (1 << (index & 31))) != 0;
	}

	public function set(value:Int, present:Bool):Void {
		var index = positions.get(value);
		if (index == null)
			return;
		if (present)
			words[index >>> 5] |= 1 << (index & 31);
		else
			words[index >>> 5] &= ~(1 << (index & 31));
	}

	public function remove(value:Int):Void
		set(value, false);

	public function intersect(other:NonNullFactSet):Void
		for (index in 0...words.length)
			words[index] &= other.words[index];

	public function same(other:NonNullFactSet):Bool {
		for (index in 0...words.length)
			if (words[index] != other.words[index])
				return false;
		return true;
	}
}

/** Must facts at instruction entry; SSA values are never invalidated by a call or a store. */
class IrNonNullFacts {
	final proven:Map<Int, Map<Int, Bool>> = [];

	/** Whether any instruction of `fn` has a receiver whose non-nullness could be proven: without one there is nothing to analyze. */
	static function hasReceiver(fn:IrFunction):Bool {
		for (block in fn.blocks)
			for (located in block.instructions)
				if (checked(located.value) != null)
					return true;
		return false;
	}

	public function new(fn:IrFunction, ?checkedDereferences:Bool = false) {
		if (!hasReceiver(fn))
			return;
		var receivers:Map<Int, Bool> = [],
			nulls:Map<Int, Bool> = [],
			tests:Map<Int, Int> = [],
			fresh:Map<Int, Bool> = [];
		var hasTry = false;
		for (block in fn.blocks)
			for (located in block.instructions) {
				var receiver = checked(located.value);
				if (receiver != null)
					receivers.set(receiver.id, true);
				switch located.value {
					case ConstNull(out):
						nulls.set(out.id, true);
					case NewObject(out, _), ValueInit(out), StaticClosure(out, _), InstanceClosure(out, _, _):
						fresh.set(out.id, true);
					case BeginTry(_, _, _), EndTry(_, _), Catch(_):
						hasTry = true;
					default:
				}
			}
		if (!receivers.keys().hasNext())
			return;
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case Equal(out, left, right):
						if (nulls.exists(left.id))
							tests.set(out.id, right.id);
						else if (nulls.exists(right.id))
							tests.set(out.id, left.id);
					default:
				}
		var graph = new IrGraph(fn),
			incoming:Map<Int, NonNullFactSet> = [],
			outgoing:Map<Int, NonNullFactSet> = [];
		// A fact can affect a receiver through an upcast or phi even if it is not itself a receiver.
		var positions:Map<Int, Int> = [], count = 0;
		function include(value:IrValue):Void
			if (!positions.exists(value.id))
				positions.set(value.id, count++);
		for (argument in fn.arguments)
			include(argument);
		for (block in fn.blocks)
			for (located in block.instructions) {
				var out = IrOperands.output(located.value);
				if (out != null)
					include(out);
			}
		var wordCount = (count + 31) >>> 5;
		var empty = new NonNullFactSet(positions, [for (_ in 0...wordCount) 0]);
		var topWords = [for (_ in 0...wordCount) -1];
		if ((count & 31) != 0)
			topWords[wordCount - 1] = -1 >>> (32 - (count & 31));
		var top = new NonNullFactSet(positions, topWords);
		if (!hasTry) {
			for (id in graph.order)
				outgoing.set(id, top.copy());
			var changed = true;
			while (changed) {
				changed = false;
				for (id in graph.order) {
					var before = empty.copy(),
						preds = graph.predecessors.get(id);
					if (id != fn.blocks[0].id && preds != null && preds.length > 0) {
						before = edge(graph, preds[0], id, outgoing, tests, empty);
						for (i in 1...preds.length) {
							var other = edge(graph, preds[i], id, outgoing, tests, empty);
							before.intersect(other);
						}
					}
					incoming.set(id, before);
					var after = before.copy();
					for (located in graph.block(id).instructions)
						transfer(located.value, after, graph, id, outgoing, tests, true, checkedDereferences);
					if (!equal(outgoing.get(id), after)) {
						outgoing.set(id, after);
						changed = true;
					}
				}
			}
		}
		for (block in fn.blocks) {
			var incomingFacts = incoming.get(block.id),
				facts = incomingFacts == null ? empty.copy() : incomingFacts.copy(),
				at:Map<Int, Bool> = [];
			// Fresh SSA definitions stay non-null even when exception edges prevent propagating check facts.
			if (hasTry)
				for (value in fresh.keys())
					facts.set(value, true);
			for (index in 0...block.instructions.length) {
				var located = block.instructions[index],
					receiver = checked(located.value);
				if (receiver != null && facts.exists(receiver.id))
					at.set(index, true);
				transfer(located.value, facts, graph, block.id, outgoing, tests, !hasTry, checkedDereferences);
			}
			proven.set(block.id, at);
		}
	}

	public function has(block:Int, index:Int):Bool {
		var at = proven.get(block);
		return at != null && at.exists(index);
	}

	static function checked(instruction:IrInstruction):Null<IrValue>
		return switch instruction {
			case Call(_, name, arguments) if (name == IrReceiverCheck.NAME && arguments.length == 1): arguments[0];
			case FieldGet(_, v, _), FieldSet(v, _, _), MethodCall(_, v, _, _, _), InstanceClosure(_, _, v), ArrayGet(_, v, _), ArraySet(v, _, _),
				ArraySize(_, v), IteratorNew(_, v), IteratorHasNext(_, v), IteratorNext(_, v), EnumIndex(_, v), EnumField(_, v, _, _): v;
			default: null;
		}

	static function isExplicitCheck(instruction:IrInstruction):Bool
		return switch instruction {
			case Call(_, name, arguments) if (name == IrReceiverCheck.NAME && arguments.length == 1): true;
			case MethodCall(_, _, _, _, _): true;
			default: false;
		}

	static function transfer(instruction:IrInstruction, facts:NonNullFactSet, graph:IrGraph, block:Int, outgoing:Map<Int, NonNullFactSet>,
			tests:Map<Int, Int>, allowPhi:Bool, checkedDereferences:Bool):Void {
		var receiver = checked(instruction);
		if (receiver != null && (checkedDereferences || isExplicitCheck(instruction)))
			facts.set(receiver.id, true);
		switch instruction {
			case NewObject(out, _), ValueInit(out), StaticClosure(out, _), InstanceClosure(out, _, _):
				facts.set(out.id, true);
			case Upcast(out, value):
				if (facts.exists(value.id))
					facts.set(out.id, true);
			case Phi(out, inputs) if (allowPhi && inputs.length > 0):
				var all = true;
				for (input in inputs) {
					if (!edgeHas(graph, input.block, block, outgoing, tests, input.value.id)) {
						all = false;
						break;
					}
				}
				if (all)
					facts.set(out.id, true);
				else
					facts.remove(out.id);
			default:
		}
	}

	static function edge(graph:IrGraph, from:Int, to:Int, outgoing:Map<Int, NonNullFactSet>, tests:Map<Int, Int>, empty:NonNullFactSet):NonNullFactSet {
		var known = outgoing.get(from),
			result = known == null ? empty.copy() : known.copy();
		if (!graph.blocks.exists(from))
			return result;
		var term = graph.block(from).terminator;
		if (term != null)
			switch term.value {
				case Branch(condition, yes, no) if (yes != no && no == to && tests.exists(condition.id)):
					result.set(tests.get(condition.id), true);
				default:
			}
		return result;
	}

	static function edgeHas(graph:IrGraph, from:Int, to:Int, outgoing:Map<Int, NonNullFactSet>, tests:Map<Int, Int>, value:Int):Bool {
		var known = outgoing.get(from);
		if (known != null && known.exists(value))
			return true;
		if (!graph.blocks.exists(from))
			return false;
		var term = graph.block(from).terminator;
		return term != null && (switch term.value {
			case Branch(condition, yes, no) if (yes != no && no == to && tests.exists(condition.id)): tests.get(condition.id) == value;
			default: false;
		});
	}

	static function equal(a:Null<NonNullFactSet>, b:NonNullFactSet):Bool
		return a != null && a.same(b);
}
