package compiler.hl.lower;

import compiler.ir.model.Ir.IrType;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrValueId;

/**
 * The lowering decisions both HashLink backends make the same way: the bytecode (`HlLower`) and the C of the AOT backend
 * (`HlcFunctionLower`). Each backend writes the decision in its own form; what is decided lives here once, so the two cannot
 * drift apart.
 */
class HlLoweringDecisions {
	/**
	 * The value row `row` dereferences and checks for null first, or no value. A native field, enum or array load cannot turn
	 * a hardware fault into a Haxe exception, so the check is explicit and the active handler works on every thread.
	 */
	public static function receiverOf(body:IrBody, row:Int):IrValueId
		return switch body.opcode(row) {
			case IrOpcode.FieldGet, IrOpcode.FieldSet, IrOpcode.MethodCall, IrOpcode.InstanceClosure, IrOpcode.ArrayGet,
				IrOpcode.ArraySet, IrOpcode.ArraySize, IrOpcode.IteratorNew, IrOpcode.IteratorHasNext,
				IrOpcode.IteratorNext,
				IrOpcode.EnumIndex, IrOpcode.EnumField:
				body.operand(row, 0);
			default: IrValueId.of(-1);
		};

	/**
	 * Whether a row of opcode `opcode` leaves every proven array bound intact: it runs no code and shrinks no array. Anything
	 * else, including every call, forgets them. Array writes only ever grow an array, so they keep them.
	 */
	public static function keepsArrayBounds(opcode:IrOpcode):Bool
		return switch opcode {
			case IrOpcode.ConstVoid, IrOpcode.ConstInt, IrOpcode.ConstFloat, IrOpcode.ConstString, IrOpcode.ConstBool,
				IrOpcode.ConstNull, IrOpcode.TypeValue, IrOpcode.ToDyn, IrOpcode.IntToFloat, IrOpcode.IntToInt64,
				IrOpcode.FloatToInt, IrOpcode.FloatToFloat, IrOpcode.Add, IrOpcode.Sub, IrOpcode.Mul, IrOpcode.BitAnd,
				IrOpcode.BitXor, IrOpcode.BitOr, IrOpcode.ShiftLeft, IrOpcode.ShiftRight, IrOpcode.UnsignedShiftRight,
				IrOpcode.Less, IrOpcode.LessEqual, IrOpcode.Equal, IrOpcode.FieldGet, IrOpcode.ArrayGet,
				IrOpcode.ArraySet, IrOpcode.ArraySize, IrOpcode.Phi: true;
			default: false;
		};

	/**
	 * Whether row `row` boxes an array (`ToDyn`) only for the next row to cast it back to an array (`SafeCast`), as a coercion
	 * between array types does: HashLink arrays carry no element type, so the cast takes the array itself and the box is not
	 * made. `uses` counts the operands that read each value.
	 */
	public static function isArrayRecast(body:IrBody, row:Int, uses:Array<Int>):Bool {
		if (body.opcode(row) != IrOpcode.ToDyn)
			return false;
		var boxed = body.output(row), next = body.nextRow(row);
		return next >= 0 && body.opcode(next) == IrOpcode.SafeCast && (body.operand(next, 0):Int) == (boxed:Int)
			&& uses[boxed] == 1 && isArray(body.valueType(body.operand(row, 0)))
			&& isArray(body.valueType(body.output(next)));
	}

	static function isArray(type:IrType):Bool
		return switch type {
			case Array(_): true;
			default: false;
		};
}
