package compiler.hl;

/** Operand shapes for the HashLink instructions emitted by this compiler. */
class HlOpcodeSchema {
	public static inline final VARIABLE_ARITY = -1;
	public static inline final UNSUPPORTED = -2;
	public static inline final VARIABLE_COUNT_OPERAND = 2;

	public static function arity(opcode:Int):Int
		return switch opcode {
			case HlOpcode.Label: 0;
			case HlOpcode.Null, HlOpcode.JAlways, HlOpcode.Ret, HlOpcode.Throw, HlOpcode.Rethrow, HlOpcode.EndTrap, HlOpcode.New: 1;
			case HlOpcode.Mov, HlOpcode.Int, HlOpcode.Float, HlOpcode.Bool, HlOpcode.String, HlOpcode.StaticClosure, HlOpcode.GetGlobal, HlOpcode.SetGlobal,
				HlOpcode.ToDyn, HlOpcode.ToSFloat, HlOpcode.ToInt, HlOpcode.SafeCast, HlOpcode.ToVirtual, HlOpcode.Trap, HlOpcode.ArraySize, HlOpcode.Type,
				HlOpcode.JTrue, HlOpcode.Call0, HlOpcode.EnumAlloc, HlOpcode.EnumIndex: 2;
			case HlOpcode.Add, HlOpcode.Sub, HlOpcode.Mul, HlOpcode.SDiv, HlOpcode.SMod, HlOpcode.Shl, HlOpcode.SShr, HlOpcode.UShr, HlOpcode.And,
				HlOpcode.Or, HlOpcode.Xor, HlOpcode.Call1, HlOpcode.InstanceClosure, HlOpcode.Field, HlOpcode.SetField, HlOpcode.GetArray, HlOpcode.SetArray,
				HlOpcode.JSLt, HlOpcode.JSLte, HlOpcode.JEq: 3;
			case HlOpcode.Call2, HlOpcode.EnumField: 4;
			case HlOpcode.CallN, HlOpcode.CallMethod, HlOpcode.CallThis, HlOpcode.CallClosure, HlOpcode.MakeEnum: VARIABLE_ARITY;
			default: UNSUPPORTED;
		}

	public static function validate(opcode:Int, operands:Array<Int>):Void {
		var expected = arity(opcode);
		if (expected == UNSUPPORTED)
			throw 'Unsupported patch opcode $opcode';
		if (expected == VARIABLE_ARITY) {
			if (operands.length <= VARIABLE_COUNT_OPERAND)
				throw 'Missing variable operand count for opcode $opcode';
			var count = operands[VARIABLE_COUNT_OPERAND];
			if (count < 0 || count > 0x1000000 || operands.length != VARIABLE_COUNT_OPERAND + 1 + count)
				throw 'Invalid variable operands for opcode $opcode';
		} else if (operands.length != expected)
			throw 'Opcode $opcode expects $expected operands, got ${operands.length}';
	}
}
