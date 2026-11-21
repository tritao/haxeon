package compiler.ir;

import compiler.ir.Ir;

/** Remove receiver checks only when a shared must-analysis proves the receiver non-null. */
class IrReceiverCheckElision {
	/** `scratch` is the caller's, reused across functions (`IrPassScratch`). */
	public static function run(fn:IrFunction, ?scratch:IrPassScratch):IrFunction {
		// Most functions have no receiver check: find that out before collecting every use.
		var hasCheck = false;
		for (block in fn.blocks) {
			for (located in block.instructions)
				switch located.value {
					case Call(_, name, _) if (name.name == IrReceiverCheck.NAME): hasCheck = true;
					default:
				}
			if (hasCheck)
				break;
		}
		if (!hasCheck)
			return fn;
		var tables = scratch ?? new IrPassScratch(), uses = tables.marked;
		uses.clear();
		for (block in fn.blocks) {
			for (located in block.instructions) {
				for (operand in 0...IrOperands.count(located.value)) uses.add(IrOperands.at(located.value, operand).id);
				switch located.value {
					case Phi(_, inputs): for (input in inputs) uses.add(input.value.id);
					default:
				}
			}
			if (block.terminator != null) switch block.terminator.value {
				case Return(value), Throw(value), Rethrow(value), Branch(value, _, _),
					Switch(value, _, _): uses.add(value.id);
				case Jump(_), Unreachable:
			}
		}
		for (binding in fn.debugBindings) uses.add(binding.value.id);
		var facts = new IrNonNullFacts(fn, false, null, tables.nonNull);
		return IrFunctionRewrite.dropInstructions(fn, function(block, index, located) {
			return switch located.value {
				case Call(output, name, arguments) if (name.name == IrReceiverCheck.NAME && arguments.length == 1):
					!uses.has(output.id) && facts.has(block.id, index);
				default: false;
			};
		});
	}

	/** `run` on a body, in place; whether it changed the body. */
	public static function runBody(body:IrBody, scratch:IrPassScratch):Bool {
		var check = IrSymbol.of(IrReceiverCheck.NAME).id, hasCheck = false;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0 && !hasCheck) {
				hasCheck = body.opcode(row) == IrOpcode.Call && body.aux(row) == check;
				row = body.nextRow(row);
			}
			if (hasCheck)
				break;
		}
		if (!hasCheck)
			return false;
		var uses = scratch.marked;
		uses.clear();
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				for (index in 0...body.operandCount(row))
					uses.add(body.operand(row, index));
				row = body.nextRow(row);
			}
		}
		for (index in 0...body.bindingCount())
			uses.add(body.bindingValue(index));
		var proven = IrNonNullFacts.analyzeBody(body, false, scratch.bodyGraph.reset(body), scratch.nonNull),
			changed = false;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var next = body.nextRow(row);
				if (body.opcode(row) == IrOpcode.Call && body.aux(row) == check && body.operandCount(row) == 1
					&& !uses.has(body.output(row)) && proven.has(row)) {
					body.removeRow(block, row);
					changed = true;
				}
				row = next;
			}
		}
		return changed;
	}
}
