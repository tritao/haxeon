package compiler.ir;

import compiler.ir.Ir;

/** Remove unused computations that cannot observe memory, allocate, call, or throw. */
class IrDeadPureValues {
	public static function removable(instruction:IrInstruction):Bool return switch instruction {
		case Phi(_, _), ConstVoid(_), ConstInt(_, _), ConstFloat(_, _), ConstBool(_, _), ConstNull(_),
			Add(_, _, _), Sub(_, _, _), Mul(_, _, _), BitAnd(_, _, _), BitOr(_, _, _), BitXor(_, _, _),
			ShiftLeft(_, _, _), ShiftRight(_, _, _), UnsignedShiftRight(_, _, _): true;
		default: false;
	};

	/** What replaces a removed instruction: nothing. Shared, since the rewrite only reads it. */
	static final none:Array<compiler.ir.SourceProvenance.Located<IrInstruction>> = [];

	public static function run(fn:IrFunction):IrFunction {
		var definitions:Map<Int, IrInstruction> = [], live:Map<Int, Bool> = [], pending:Array<IrValue> = [];
		function mark(value:IrValue):Void {
			if (!live.exists(value.id)) {
				live.set(value.id, true);
				pending.push(value);
			}
		}
		function inputs(instruction:IrInstruction):Void {
			for (value in IrOperands.inputs(instruction)) mark(value);
			switch instruction {
				case Phi(_, values): for (input in values) mark(input.value);
				default:
			}
		}
		for (block in fn.blocks) {
			for (located in block.instructions) {
				var instruction = located.value, output = IrOperands.output(instruction);
				if (output != null) definitions.set(output.id, instruction);
				if (!removable(instruction)) inputs(instruction);
			}
			if (block.terminator != null) switch block.terminator.value {
				case Return(value), Throw(value), Rethrow(value), Branch(value, _, _): mark(value);
				case Jump(_):
			}
		}
		for (binding in fn.debugBindings) mark(binding.value);
		while (pending.length > 0) {
			var value = pending.pop(), definition = definitions.get(value.id);
			if (definition != null) inputs(definition);
		}
		return IrFunctionRewrite.instructions(fn, located -> {
			var output = IrOperands.output(located.value);
			return output != null && !live.exists(output.id) && removable(located.value) ? none : null;
		});
	}
}
