package compiler.ir;

import compiler.ir.Ir;

/** Must facts at instruction entry; SSA values are never invalidated by a call or a store. */
class IrNonNullFacts {
	final proven:Map<Int, Map<Int, Bool>> = [];

	public function new(fn:IrFunction, ?checkedDereferences:Bool = false) {
		var receivers:Map<Int, Bool> = [], nulls:Map<Int, Bool> = [], tests:Map<Int, Int> = [], fresh:Map<Int, Bool> = [];
		var hasTry = false;
		for (block in fn.blocks) for (located in block.instructions) {
			var receiver = checked(located.value);
			if (receiver != null) receivers.set(receiver.id, true);
			switch located.value {
				case ConstNull(out): nulls.set(out.id, true);
				case NewObject(out, _), StaticClosure(out, _), InstanceClosure(out, _, _): fresh.set(out.id, true);
				case BeginTry(_, _, _), EndTry(_, _), Catch(_): hasTry = true;
				default:
			}
		}
		if (!receivers.keys().hasNext()) return;
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case Equal(out, left, right):
				if (nulls.exists(left.id)) tests.set(out.id, right.id);
				else if (nulls.exists(right.id)) tests.set(out.id, left.id);
			default:
		}
		var graph = new IrGraph(fn), incoming:Map<Int, Map<Int, Bool>> = [], outgoing:Map<Int, Map<Int, Bool>> = [];
		// A fact can affect a receiver through an upcast or phi even if it is not itself a receiver.
		var top:Map<Int, Bool> = [];
		for (argument in fn.arguments) top.set(argument.id, true);
		for (block in fn.blocks) for (located in block.instructions) {
			var out = IrOperands.output(located.value);
			if (out != null) top.set(out.id, true);
		}
		if (!hasTry) {
			for (id in graph.order) outgoing.set(id, copy(top));
			var changed = true;
			while (changed) {
				changed = false;
				for (id in graph.order) {
					var before:Map<Int, Bool> = [], preds = graph.predecessors.get(id);
					if (id != fn.blocks[0].id && preds != null && preds.length > 0) {
						before = edge(graph, preds[0], id, outgoing, tests);
						for (i in 1...preds.length) {
							var other = edge(graph, preds[i], id, outgoing, tests), common:Map<Int, Bool> = [];
							for (v in before.keys()) if (other.exists(v)) common.set(v, true);
							before = common;
						}
					}
					incoming.set(id, before);
					var after = copy(before);
					for (located in graph.block(id).instructions) transfer(located.value, after, graph, id, outgoing, tests, true, checkedDereferences);
					if (!equal(outgoing.get(id), after)) { outgoing.set(id, after); changed = true; }
				}
			}
		}
		for (block in fn.blocks) {
			var facts = copy(incoming.get(block.id)), at:Map<Int, Bool> = [];
			// Fresh SSA definitions stay non-null even when exception edges prevent propagating check facts.
			if (hasTry) for (value in fresh.keys()) facts.set(value, true);
			for (index in 0...block.instructions.length) {
				var located = block.instructions[index], receiver = checked(located.value);
				if (receiver != null && facts.exists(receiver.id)) at.set(index, true);
				transfer(located.value, facts, graph, block.id, outgoing, tests, !hasTry, checkedDereferences);
			}
			proven.set(block.id, at);
		}
	}

	public function has(block:Int, index:Int):Bool {
		var at = proven.get(block);
		return at != null && at.exists(index);
	}

	static function checked(instruction:IrInstruction):Null<IrValue> return switch instruction {
		case Call(_, name, arguments) if (name == IrReceiverCheck.NAME && arguments.length == 1): arguments[0];
		case FieldGet(_, v, _), FieldSet(v, _, _), MethodCall(_, v, _, _, _), InstanceClosure(_, _, v), ArrayGet(_, v, _),
			 ArraySet(v, _, _), ArraySize(_, v), IteratorNew(_, v), IteratorHasNext(_, v), IteratorNext(_, v),
			 EnumIndex(_, v), EnumField(_, v, _, _): v;
		default: null;
	}

	static function isExplicitCheck(instruction:IrInstruction):Bool return switch instruction {
		case Call(_, name, arguments) if (name == IrReceiverCheck.NAME && arguments.length == 1): true;
		case MethodCall(_, _, _, _, _): true;
		default: false;
	}

	static function transfer(instruction:IrInstruction, facts:Map<Int, Bool>, graph:IrGraph, block:Int,
			outgoing:Map<Int, Map<Int, Bool>>, tests:Map<Int, Int>, allowPhi:Bool, checkedDereferences:Bool):Void {
		var receiver = checked(instruction);
		if (receiver != null && (checkedDereferences || isExplicitCheck(instruction))) facts.set(receiver.id, true);
		switch instruction {
			case NewObject(out, _), StaticClosure(out, _), InstanceClosure(out, _, _): facts.set(out.id, true);
			case Upcast(out, value): if (facts.exists(value.id)) facts.set(out.id, true);
			case Phi(out, inputs) if (allowPhi && inputs.length > 0):
				var all = true;
				for (input in inputs) {
					var e = edge(graph, input.block, block, outgoing, tests);
					if (!e.exists(input.value.id)) { all = false; break; }
				}
				if (all) facts.set(out.id, true); else facts.remove(out.id);
			default:
		}
	}

	static function edge(graph:IrGraph, from:Int, to:Int, outgoing:Map<Int, Map<Int, Bool>>, tests:Map<Int, Int>):Map<Int, Bool> {
		var result = copy(outgoing.get(from));
		if (!graph.blocks.exists(from)) return result;
		var term = graph.block(from).terminator;
		if (term != null) switch term.value {
			case Branch(condition, yes, no) if (yes != no && no == to && tests.exists(condition.id)):
				result.set(tests.get(condition.id), true);
			default:
		}
		return result;
	}

	static function copy(source:Null<Map<Int, Bool>>):Map<Int, Bool> {
		var result:Map<Int, Bool> = [];
		if (source != null) for (id in source.keys()) result.set(id, true);
		return result;
	}
	static function equal(a:Null<Map<Int, Bool>>, b:Map<Int, Bool>):Bool {
		if (a == null) return false;
		for (id in a.keys()) if (!b.exists(id)) return false;
		for (id in b.keys()) if (!a.exists(id)) return false;
		return true;
	}
}
