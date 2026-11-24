package compiler.ir.passes.cleanup;

import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrPassScratch;
import compiler.ir.model.IrValueId;

/** Remove unused computations that cannot observe memory, allocate, call, or throw. */
@:nullSafety(Strict)
class IrDeadPureValues {
	/** Whether a row with this opcode computes a value without observing memory, allocating, calling or throwing. */
	public static function removableOpcode(opcode:IrOpcode):Bool
		return switch opcode {
			case IrOpcode.ValueInit, IrOpcode.Phi, IrOpcode.ConstVoid, IrOpcode.ConstInt, IrOpcode.ConstFloat,
				IrOpcode.ConstBool, IrOpcode.ConstNull, IrOpcode.Add, IrOpcode.Sub, IrOpcode.Mul, IrOpcode.BitAnd,
				IrOpcode.BitOr, IrOpcode.BitXor, IrOpcode.ShiftLeft, IrOpcode.ShiftRight,
				IrOpcode.UnsignedShiftRight: true;
			default: false;
		};

	/** On a body, in place; whether it removed anything. */
	public static function runBody(body:IrBody, scratch:IrPassScratch):Bool {
		var live = scratch.marked, pending = scratch.pendingIds;
		live.clear();
		pending.resize(0);
		inline function markOperands(row:Int):Void
			for (index in 0...body.operandCount(row)) {
				var value = body.operand(row, index);
				if (live.add(value))
					pending.push(value);
			}
		// Terminators are not removable, so their operands are marked with every other row that stays.
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (!removableOpcode(body.opcode(row)))
					markOperands(row);
				row = body.nextRow(row);
			}
		}
		for (index in 0...body.bindingCount()) {
			var value = body.bindingValue(index);
			if (live.add(value))
				pending.push(value);
		}
		while (pending.length > 0) {
			var value = IrValueId.of(pending[pending.length - 1]);
			pending.resize(pending.length - 1);
			var definition = (value:Int) < body.valueLimit() ? body.definingRow(value) : -1;
			if (definition >= 0)
				markOperands(definition);
		}
		var removed = false;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var next = body.nextRow(row), output = body.output(row);
				if (output.exists() && !live.has(output) && removableOpcode(body.opcode(row))) {
					body.removeRow(block, row);
					removed = true;
				}
				row = next;
			}
		}
		return removed;
	}
}
