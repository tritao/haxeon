package compiler.ir;

import compiler.ir.Ir;

/** Remove receiver checks only when the same SSA reference is already known non-null. */
class IrReceiverCheckElision {
	public static function run(fn:IrFunction):IrFunction {
		var fresh:Map<Int, Bool> = [], uses:Map<Int, Bool> = [], checkedValues:Map<Int, Bool> = [], hasCheck = false, hasTry = false;
		for (block in fn.blocks) {
			for (located in block.instructions) {
				var instruction = located.value;
				for (value in IrOperands.inputs(instruction)) uses.set(value.id, true);
				switch instruction {
					case Phi(_, inputs): for (input in inputs) uses.set(input.value.id, true);
					case NewObject(out, _), StaticClosure(out, _), InstanceClosure(out, _, _): fresh.set(out.id, true);
					case Call(_, name, arguments) if (name == IrReceiverCheck.NAME):
						hasCheck = true;
						if (arguments.length == 1) checkedValues.set(arguments[0].id, true);
					case BeginTry(_, _, _), EndTry(_, _), Catch(_): hasTry = true;
					default:
				}
			}
			if (block.terminator != null) switch block.terminator.value {
				case Return(value), Throw(value), Rethrow(value), Branch(value, _, _): uses.set(value.id, true);
				case Jump(_):
			}
		}
		for (binding in fn.debugBindings) uses.set(binding.value.id, true);
		if (!hasCheck) return fn;

		// A handler can be entered before a check in the same block. Until the graph carries per-instruction exception
		// edges, do not propagate check facts between blocks in functions with handlers.
		var graph = new IrGraph(fn), incoming:Map<Int, Map<Int, Bool>> = [], outgoing:Map<Int, Map<Int, Bool>> = [];
		if (!hasTry) {
			// Must-analysis starts at the universal set and shrinks. Starting with empty sets would miss facts that
			// dominate a loop, because the back edge would never acquire them.
			for (id in graph.order) outgoing.set(id, copyFacts(checkedValues));
			var changed = true;
			while (changed) {
				changed = false;
				for (id in graph.order) {
					var facts:Map<Int, Bool> = [], predecessors = graph.predecessors.get(id);
					if (id != fn.blocks[0].id && predecessors != null && predecessors.length > 0) {
						var first = outgoing.get(predecessors[0]);
						if (first != null) for (value in first.keys()) {
							var common = true;
							for (pred in predecessors) {
								var values = outgoing.get(pred);
								if (values == null || !values.exists(value)) { common = false; break; }
							}
							if (common) facts.set(value, true);
						}
					}
					incoming.set(id, facts);
					var after = copyFacts(facts);
					for (located in graph.block(id).instructions) switch located.value {
						case Call(_, name, arguments) if (name == IrReceiverCheck.NAME && arguments.length == 1): after.set(arguments[0].id, true);
						default:
					}
					if (!sameFacts(outgoing.get(id), after)) { outgoing.set(id, after); changed = true; }
				}
			}
		}
		var changed = false, blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var copy = new IrBlock(block.id), facts = copyFacts(incoming.get(block.id));
			for (located in block.instructions) {
				var drop = false;
				switch located.value {
					case Call(output, name, arguments) if (name == IrReceiverCheck.NAME && arguments.length == 1):
						var id = arguments[0].id;
						drop = !uses.exists(output.id) && (fresh.exists(id) || facts.exists(id));
						facts.set(id, true);
					default:
				}
				if (drop) changed = true; else copy.instructions.push(located);
			}
			copy.terminator = block.terminator;
			blocks.push(copy);
		}
		return changed ? new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention) : fn;
	}

	static function copyFacts(source:Null<Map<Int, Bool>>):Map<Int, Bool> {
		var copy:Map<Int, Bool> = [];
		if (source != null) for (value in source.keys()) copy.set(value, true);
		return copy;
	}

	static function sameFacts(a:Null<Map<Int, Bool>>, b:Map<Int, Bool>):Bool {
		if (a == null) return false;
		for (value in a.keys()) if (!b.exists(value)) return false;
		for (value in b.keys()) if (!a.exists(value)) return false;
		return true;
	}
}
