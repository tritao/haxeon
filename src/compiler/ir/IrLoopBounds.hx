package compiler.ir;

import compiler.ir.Ir;

private typedef BoundsLoop = {final header:Int; final members:Map<Int, Bool>;}

/** Read-only proofs for unit-step counted loops, including the pre-increment form emitted by SsaBuilder. */
class IrLoopBounds {
	final graph:IrGraph;
	final loops:Array<BoundsLoop> = [];
	final definitions:Map<Int, IrInstruction> = [];
	final homes:Map<Int, Int> = [];
	final pureCalls:Map<String, Bool>;
	final hasHandlers:Bool;

	public function new(fn:IrFunction, pureCalls:Map<String, Bool>) {
		this.pureCalls = pureCalls;
		graph = new IrGraph(fn);
		var handlers = false;
		for (block in fn.blocks)
			for (located in block.instructions) {
				var output = IrOperands.output(located.value);
				if (output != null) {
					definitions.set(output.id, located.value);
					homes.set(output.id, block.id);
				}
				switch located.value {
					case BeginTry(_, _), EndTry(_), Catch(_):
						handlers = true;
					default:
				}
			}
		hasHandlers = handlers;
		for (tail in graph.order)
			for (header in graph.successors.get(tail))
				if (graph.dominates(header, tail)) {
					var loop:Null<BoundsLoop> = null;
					for (candidate in loops)
						if (candidate.header == header)
							loop = candidate;
					if (loop == null) {
						loop = {header: header, members: []};
						loops.push(loop);
					}
					loop.members.set(header, true);
					var pending:Array<Int> = [tail];
					while (pending.length > 0) {
						var id = pending.pop();
						if (id == null || loop.members.exists(id))
							continue;
						loop.members.set(id, true);
						for (pred in graph.predecessors.get(id))
							pending.push(pred);
					}
				}
	}

	/** Whitelist by ABI binding, not by source function name. These implementations accept only scalar arguments. */
	public static function pureNativeCalls(natives:Array<IrNative>):Map<String, Bool> {
		var result:Map<String, Bool> = [];
		for (native in natives)
			if (native.library == "haxeon_runtime")
				switch native.symbol {
					case "__math_sqrt", "__math_abs", "__math_floor", "__math_ceil", "__math_min", "__math_max", "__math_is_finite", "__math_is_nan":
						var scalar = native.result == F64 || native.result == I32 || native.result == Bool;
						for (argument in native.arguments)
							if (argument != F64 && argument != I32 && argument != Bool)
								scalar = false;
						if (scalar)
							result.set(native.name, true);
					default:
				}
		return result;
	}

	public function depth(block:Int):Int {
		var result = 0;
		for (loop in loops)
			if (loop.members.exists(block))
				result++;
		return result;
	}

	public function definition(value:Int):Null<IrInstruction>
		return definitions.get(value);

	public function invariantInputs(instruction:IrInstruction, block:Int):Bool {
		for (loop in loops)
			if (loop.members.exists(block)) {
				var invariant = true;
				for (input in IrOperands.inputs(instruction)) {
					var home = homes.get(input.id);
					if (home != null && loop.members.exists(home))
						switch definitions.get(input.id) {
							case ConstInt(_, _), ConstFloat(_, _), ConstBool(_, _):
							default:
								invariant = false;
						}
				}
				if (invariant)
					return true;
			}
		return false;
	}

	public function proven(array:IrValue, index:IrValue, accessBlock:Int):Bool {
		if (hasHandlers)
			return false;
		for (loop in loops)
			if (loop.members.exists(accessBlock) && stable(loop)) {
				var start = inductionStart(index, loop);
				if (start != null && nonnegative(start, loop.header, []) && guarded(array, index, accessBlock, loop))
					return true;
			}
		return false;
	}

	function guarded(array:IrValue, index:IrValue, accessBlock:Int, loop:BoundsLoop):Bool {
		for (id in graph.order)
			if (loop.members.exists(id)) {
				var block = graph.block(id);
				if (block.terminator != null)
					switch block.terminator.value {
						case Branch(condition, yes, no) if (loop.members.exists(yes) && !loop.members.exists(no) && graph.dominates(yes, accessBlock)):
							switch definitions.get(condition.id) {
								case Less(_, left, right) if (left.id == index.id):
									switch definitions.get(right.id) {
										case ArraySize(_, receiver) if (receiver.id == array.id): return true;
										default:
									}
								default:
							}
						default:
					}
			}
		return false;
	}

	function inductionStart(index:IrValue, loop:BoundsLoop):Null<IrValue> {
		var phi = index, preincrement = false;
		switch definitions.get(index.id) {
			case Add(_, left, right) if (one(right)):
				phi = left;
				preincrement = true;
			default:
		}
		var home = homes.get(phi.id);
		if (home == null || home != loop.header || phi.type != I32)
			return null;
		var inputs = switch definitions.get(phi.id) {
			case Phi(_, incoming): incoming;
			default: return null;
		};
		var start:Null<IrValue> = null, step = false;
		for (input in inputs)
			if (!loop.members.exists(input.block)) {
				var initial = input.value;
				if (preincrement)
					switch definitions.get(initial.id) {
						case Sub(_, left, right) if (one(right)):
							initial = left;
						default:
							return null;
					}
				if (start != null && start.id != initial.id)
					return null;
				start = initial;
			} else if (preincrement) {
				if (input.value.id != index.id)
					return null;
				step = true;
			} else
				switch definitions.get(input.value.id) {
					case Add(_, left, right) if (left.id == index.id && one(right)):
						step = true;
					default:
						return null;
				}
		return step ? start : null;
	}

	function one(value:IrValue):Bool {
		var n = integer(value, []);
		return n != null && n == 1;
	}

	function integer(value:IrValue, seen:Map<Int, Bool>):Null<Int> {
		if (seen.exists(value.id))
			return null;
		seen.set(value.id, true);
		return switch definitions.get(value.id) {
			case ConstInt(_, n): n;
			case Add(_, left, right), Sub(_, left, right):
				var a = integer(left, seen), b = integer(right, seen);
				if (a == null || b == null) null; else switch definitions.get(value.id) {
					case Add(_, _, _): a + b;
					default: a - b;
				}
			default: null;
		};
	}

	function nonnegative(value:IrValue, atBlock:Int, seen:Map<Int, Bool>):Bool {
		var literal = integer(value, []);
		if (literal != null)
			return literal >= 0;
		if (seen.exists(value.id))
			return false;
		seen.set(value.id, true);
		// Nested i+1 is safe: its enclosing length guard proves i <= Int.MAX_VALUE-1.
		switch definitions.get(value.id) {
			case Add(_, left, right) if (one(right)):
				return boundedIndex(left, atBlock, seen);
			default:
				return boundedIndex(value, atBlock, seen);
		}
	}

	function boundedIndex(value:IrValue, atBlock:Int, seen:Map<Int, Bool>):Bool {
		for (loop in loops)
			if (loop.members.exists(atBlock) && stable(loop)) {
				var start = inductionStart(value, loop);
				if (start == null || !nonnegative(start, loop.header, seen))
					continue;
				for (id in graph.order)
					if (loop.members.exists(id)) {
						var block = graph.block(id);
						if (block.terminator != null)
							switch block.terminator.value {
								case Branch(condition, yes, no) if (loop.members.exists(yes) && !loop.members.exists(no) && graph.dominates(yes, atBlock)):
									switch definitions.get(condition.id) {
										case Less(_, left, right) if (left.id == value.id):
											switch definitions.get(right.id) {
												case ArraySize(_, _): return true;
												default:
											}
										default:
									}
								default:
							}
					}
			}
		return false;
	}

	function stable(loop:BoundsLoop):Bool {
		for (id in graph.order)
			if (loop.members.exists(id))
				for (located in graph.block(id).instructions)
					switch located.value {
						case Call(_, name, _) if (pureCalls.exists(name)):
						case Call(_, _, _), CNativeCall(_, _, _), CallClosure(_, _, _), MethodCall(_, _, _, _), MemoryStore(_, _, _), ArraySet(_, _, _),
							IteratorNew(_, _), IteratorNext(_, _), IteratorHasNext(_, _):
							return false;
						case FieldSet(receiver, _, _):
							switch receiver.type {
								case Obj(_):
								default: return false;
							}
						default:
					}
		return true;
	}
}
