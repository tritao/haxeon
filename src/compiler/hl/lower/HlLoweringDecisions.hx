package compiler.hl.lower;

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
}
