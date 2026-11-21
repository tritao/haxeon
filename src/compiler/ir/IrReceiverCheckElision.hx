package compiler.ir;

import compiler.ir.Ir;

/** Remove receiver checks only when a shared must-analysis proves the receiver non-null. */
class IrReceiverCheckElision {
	/** On a body, in place; whether it changed the body. `scratch` is the caller's, reused across functions. */
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
