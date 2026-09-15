package compiler.hl;

/** Operand shapes for the HashLink instructions emitted by this compiler. */
class HlOpcodeSchema {
	public static inline final VARIABLE_ARITY = -1;
	public static inline final UNSUPPORTED = -2;
	public static inline final VARIABLE_COUNT_OPERAND = 2;

	public static function arity(opcode:Int):Int
		return switch opcode {
			case HlOpcode.Label: 0;
			case HlOpcode.Null, HlOpcode.JAlways, HlOpcode.Ret, HlOpcode.Throw, HlOpcode.Rethrow, HlOpcode.NullCheck, HlOpcode.EndTrap, HlOpcode.New: 1;
			case HlOpcode.Mov, HlOpcode.Int, HlOpcode.Float, HlOpcode.Bool, HlOpcode.Bytes, HlOpcode.String, HlOpcode.StaticClosure, HlOpcode.GetGlobal,
				HlOpcode.SetGlobal, HlOpcode.GetThis, HlOpcode.SetThis, HlOpcode.ToDyn, HlOpcode.ToSFloat, HlOpcode.ToUFloat, HlOpcode.ToInt,
				HlOpcode.SafeCast, HlOpcode.UnsafeCast, HlOpcode.ToVirtual, HlOpcode.Trap, HlOpcode.Neg, HlOpcode.Not, HlOpcode.Incr, HlOpcode.Decr,
				HlOpcode.ArraySize, HlOpcode.Type, HlOpcode.GetType, HlOpcode.GetTID, HlOpcode.Ref, HlOpcode.Unref, HlOpcode.SetRef, HlOpcode.RefData,
				HlOpcode.JTrue, HlOpcode.JFalse, HlOpcode.JNull, HlOpcode.JNotNull, HlOpcode.Call0, HlOpcode.EnumAlloc, HlOpcode.EnumIndex: 2;
			case HlOpcode.Add, HlOpcode.Sub, HlOpcode.Mul, HlOpcode.SDiv, HlOpcode.UDiv, HlOpcode.SMod, HlOpcode.UMod, HlOpcode.Shl, HlOpcode.SShr,
				HlOpcode.UShr, HlOpcode.And, HlOpcode.Or, HlOpcode.Xor, HlOpcode.Call1, HlOpcode.InstanceClosure, HlOpcode.VirtualClosure, HlOpcode.Field,
				HlOpcode.SetField, HlOpcode.DynGet, HlOpcode.DynSet, HlOpcode.GetArray, HlOpcode.SetArray, HlOpcode.GetI8, HlOpcode.GetI16, HlOpcode.GetMem,
				HlOpcode.SetI8, HlOpcode.SetI16, HlOpcode.SetMem, HlOpcode.JSLt, HlOpcode.JSGte, HlOpcode.JSGt, HlOpcode.JSLte, HlOpcode.JULt, HlOpcode.JUGte,
				HlOpcode.JNotLt, HlOpcode.JNotGte, HlOpcode.JEq, HlOpcode.JNotEq, HlOpcode.RefOffset: 3;
			case HlOpcode.Call2: 4;
			case HlOpcode.Call3: 5;
			case HlOpcode.Call4: 6;
			case HlOpcode.EnumField: 4;
			case HlOpcode.CallN, HlOpcode.CallMethod, HlOpcode.CallThis, HlOpcode.CallClosure, HlOpcode.MakeEnum, HlOpcode.Switch: VARIABLE_ARITY;
			default: UNSUPPORTED;
		}

	public static function validate(opcode:Int, operands:Array<Int>):Void {
		var expected = arity(opcode);
		if (expected == UNSUPPORTED)
			throw 'Unsupported patch opcode $opcode';
		if (opcode == HlOpcode.Switch) {
			if (operands.length < 3 || operands[1] < 0 || operands.length != operands[1] + 3)
				throw 'Invalid switch operands';
			for (index in 2...operands.length)
				if (operands[index] < 0)
					throw 'Switch offsets must be unsigned';
			return;
		}
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
