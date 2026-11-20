package compiler.ir;

import compiler.ir.Ir;

/** Remove unused computations that cannot observe memory, allocate, call, or throw. */
class IrDeadPureValues {
	public static function removable(instruction:IrInstruction):Bool return switch instruction {
		case ValueInit(_), Phi(_, _), ConstVoid(_), ConstInt(_, _), ConstFloat(_, _), ConstBool(_, _), ConstNull(_),
			Add(_, _, _), Sub(_, _, _), Mul(_, _, _), BitAnd(_, _, _), BitOr(_, _, _), BitXor(_, _, _),
			ShiftLeft(_, _, _), ShiftRight(_, _, _), UnsignedShiftRight(_, _, _): true;
		default: false;
	};

	/** What replaces a removed instruction: nothing. Shared, since the rewrite only reads it. */
	@:processWide("a shared empty value, never added to")
	static final none:Array<compiler.ir.SourceProvenance.Located<IrInstruction>> = [];

	/** `scratch` is the caller's, reused across functions (`IrPassScratch`). */
	public static function run(fn:IrFunction, ?scratch:IrPassScratch):IrFunction {
		var tables = scratch ?? new IrPassScratch(),
			definitions = tables.definitions,
			live = tables.marked,
			pending = tables.pending;
		live.clear();
		pending.resize(0);
		function mark(value:IrValue):Void {
			if (live.add(value.id))
				pending.push(value);
		}
		function inputs(instruction:IrInstruction):Void {
			for (valueIndex in 0...IrOperands.count(instruction)) {
				var value = IrOperands.at(instruction, valueIndex);
				mark(value);
			}
			switch instruction {
				case Phi(_, values): for (input in values) mark(input.value);
				default:
			}
		}
		for (block in fn.blocks) {
			for (located in block.instructions) {
				var instruction = located.value, output = IrOperands.output(instruction);
				if (output != null) {
					while (definitions.length <= output.id)
						definitions.push(null);
					definitions[output.id] = instruction;
				}
				if (!removable(instruction)) inputs(instruction);
			}
			if (block.terminator != null) switch block.terminator.value {
				case Return(value), Throw(value), Rethrow(value), Branch(value, _, _), Switch(value, _, _): mark(value);
				case Jump(_), Unreachable:
			}
		}
		for (binding in fn.debugBindings) mark(binding.value);
		while (true) {
			var value = pending.pop();
			if (value == null)
				break;
			var definition = value.id < definitions.length ? definitions[value.id] : null;
			if (definition != null) inputs(definition);
		}
		var result = IrFunctionRewrite.instructions(fn, located -> {
			var output = IrOperands.output(located.value);
			return output != null && !live.has(output.id) && removable(located.value) ? none : null;
		});
		// The table keeps no instruction alive after the pass.
		for (block in fn.blocks)
			for (located in block.instructions) {
				var output = IrOperands.output(located.value);
				if (output != null)
					definitions[output.id] = null;
			}
		return result;
	}

	/** `removable` for a body row. */
	public static function removableOpcode(opcode:IrOpcode):Bool
		return switch opcode {
			case IrOpcode.ValueInit, IrOpcode.Phi, IrOpcode.ConstVoid, IrOpcode.ConstInt, IrOpcode.ConstFloat,
				IrOpcode.ConstBool, IrOpcode.ConstNull, IrOpcode.Add, IrOpcode.Sub, IrOpcode.Mul, IrOpcode.BitAnd,
				IrOpcode.BitOr, IrOpcode.BitXor, IrOpcode.ShiftLeft, IrOpcode.ShiftRight,
				IrOpcode.UnsignedShiftRight: true;
			default: false;
		};

	/** `run` on a body: the same body when nothing is removed. */
	public static function runBody(body:IrBody, scratch:IrPassScratch):IrBody {
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
		for (row in 0...body.rowCount())
			if (!removableOpcode(body.opcode(row)))
				markOperands(row);
		for (index in 0...body.bindingCount()) {
			var value = body.bindingValue(index);
			if (live.add(value))
				pending.push(value);
		}
		while (pending.length > 0) {
			var value = pending[pending.length - 1];
			pending.resize(pending.length - 1);
			var definition = value < body.valueLimit() ? body.definingRow(value) : -1;
			if (definition >= 0)
				markOperands(definition);
		}
		var dead = 0;
		for (row in 0...body.rowCount()) {
			var output = body.output(row);
			if (output >= 0 && !live.has(output) && removableOpcode(body.opcode(row)))
				dead++;
		}
		if (dead == 0)
			return body;
		var builder = scratch.bodyBuilder;
		builder.startFrom(body);
		for (block in 0...body.blockCount()) {
			builder.beginBlock(body.blockId(block));
			for (row in body.firstRow(block)...body.endRow(block)) {
				var output = body.output(row);
				if (output < 0 || live.has(output) || !removableOpcode(body.opcode(row)))
					builder.copyRow(body, row);
			}
		}
		for (index in 0...body.bindingCount())
			builder.copyBinding(body, index, body.bindingValue(index));
		return builder.finishFrom(body);
	}
}
