package compiler.hl;

import compiler.core.InternalError;

/** Operand shapes for the HashLink instructions emitted by this compiler. */
class HlOpcodeSchema {
	public static inline final VARIABLE_ARITY = -1;

	/** OSwitch: the register, the table size, one offset per entry, and the end offset. */
	public static inline final SWITCH_ARITY = -3;
	public static inline final UNSUPPORTED = -2;
	public static inline final VARIABLE_COUNT_OPERAND = 2;

	public static function arity(opcode:Int):Int
		return switch opcode {
			case HlOpcode.Label: 0;
			case HlOpcode.NullCheck, HlOpcode.Null, HlOpcode.JAlways, HlOpcode.Ret, HlOpcode.Throw, HlOpcode.Rethrow,
				HlOpcode.EndTrap, HlOpcode.EndCleanupTrap, HlOpcode.New: 1;
			case HlOpcode.Mov, HlOpcode.Int, HlOpcode.Float, HlOpcode.Bool, HlOpcode.String, HlOpcode.StaticClosure,
				HlOpcode.GetGlobal, HlOpcode.SetGlobal,
				HlOpcode.ToDyn, HlOpcode.ToSFloat, HlOpcode.ToInt, HlOpcode.SafeCast, HlOpcode.UnsafeCast, HlOpcode.Ref,
				HlOpcode.Unref, HlOpcode.Setref,
				HlOpcode.ToVirtual, HlOpcode.Trap, HlOpcode.CleanupTrap, HlOpcode.ArraySize, HlOpcode.RefData,
				HlOpcode.Type, HlOpcode.GetType, HlOpcode.JTrue, HlOpcode.JNull, HlOpcode.JFalse, HlOpcode.JNotNull,
				HlOpcode.Call0,
				HlOpcode.EnumAlloc, HlOpcode.EnumIndex: 2;
			case HlOpcode.Add, HlOpcode.Sub, HlOpcode.Mul, HlOpcode.SDiv, HlOpcode.SMod, HlOpcode.Shl, HlOpcode.SShr,
				HlOpcode.UShr, HlOpcode.And,
				HlOpcode.Or, HlOpcode.Xor, HlOpcode.Call1, HlOpcode.InstanceClosure, HlOpcode.Field, HlOpcode.SetField,
				HlOpcode.GetArray, HlOpcode.SetArray,
				HlOpcode.GetI8, HlOpcode.GetI16, HlOpcode.GetMem, HlOpcode.SetI8, HlOpcode.SetI16, HlOpcode.SetMem,
				HlOpcode.JSLt, HlOpcode.JSLte,
				HlOpcode.JULt, HlOpcode.JEq, HlOpcode.JNotEq, HlOpcode.JNotLt, HlOpcode.JNotGte, HlOpcode.JSGte,
				HlOpcode.JSGt, HlOpcode.JUGte, HlOpcode.RefOffset: 3;
			case HlOpcode.Call2, HlOpcode.EnumField: 4;
			case HlOpcode.CallN, HlOpcode.CallMethod, HlOpcode.CallThis, HlOpcode.CallClosure,
				HlOpcode.MakeEnum: VARIABLE_ARITY;
			case HlOpcode.Switch: SWITCH_ARITY;
			default: UNSUPPORTED;
		}

	/**
	 * The operand count of every HashLink opcode as the VM's loader reads it (vendor/hashlink/src/opcodes.h, `hl_op_nargs` in
	 * code.c), for decoding modules any compiler wrote (HlModuleReader). `arity` is the strict subset this compiler emits, which
	 * patches are held to. HlOpcodeTableMain checks both, and `name`, against the vendored opcodes.h.
	 */
	public static function decodeArity(opcode:Int):Int
		return switch opcode {
			case HlOpcode.Label, HlOpcode.Assert, HlOpcode.Nop: 0;
			case HlOpcode.Null, HlOpcode.Incr, HlOpcode.Decr, HlOpcode.JAlways, HlOpcode.Ret, HlOpcode.Throw,
				HlOpcode.Rethrow, HlOpcode.NullCheck, HlOpcode.EndTrap, HlOpcode.New, HlOpcode.Catch,
				HlOpcode.EndCleanupTrap: 1;
			case HlOpcode.Mov, HlOpcode.Int, HlOpcode.Float, HlOpcode.Bool, HlOpcode.Bytes, HlOpcode.String,
				HlOpcode.Neg,
				HlOpcode.Not, HlOpcode.Call0, HlOpcode.StaticClosure, HlOpcode.GetGlobal, HlOpcode.SetGlobal,
				HlOpcode.GetThis,
				HlOpcode.SetThis, HlOpcode.JTrue, HlOpcode.JFalse, HlOpcode.JNull, HlOpcode.JNotNull, HlOpcode.ToDyn,
				HlOpcode.ToSFloat, HlOpcode.ToUFloat, HlOpcode.ToInt, HlOpcode.SafeCast, HlOpcode.UnsafeCast,
				HlOpcode.ToVirtual,
				HlOpcode.Trap, HlOpcode.ArraySize, HlOpcode.Type, HlOpcode.GetType, HlOpcode.GetTID, HlOpcode.Ref,
				HlOpcode.Unref, HlOpcode.Setref, HlOpcode.EnumAlloc, HlOpcode.EnumIndex, HlOpcode.RefData,
				HlOpcode.CleanupTrap: 2;
			case HlOpcode.Add, HlOpcode.Sub, HlOpcode.Mul, HlOpcode.SDiv, HlOpcode.UDiv, HlOpcode.SMod, HlOpcode.UMod,
				HlOpcode.Shl, HlOpcode.SShr, HlOpcode.UShr, HlOpcode.And, HlOpcode.Or, HlOpcode.Xor, HlOpcode.Call1,
				HlOpcode.InstanceClosure, HlOpcode.VirtualClosure, HlOpcode.Field, HlOpcode.SetField, HlOpcode.DynGet,
				HlOpcode.DynSet, HlOpcode.JSLt, HlOpcode.JSGte, HlOpcode.JSGt, HlOpcode.JSLte, HlOpcode.JULt,
				HlOpcode.JUGte,
				HlOpcode.JNotLt, HlOpcode.JNotGte, HlOpcode.JEq, HlOpcode.JNotEq, HlOpcode.GetI8, HlOpcode.GetI16,
				HlOpcode.GetMem, HlOpcode.GetArray, HlOpcode.SetI8, HlOpcode.SetI16, HlOpcode.SetMem, HlOpcode.SetArray,
				HlOpcode.SetEnumField, HlOpcode.RefOffset, HlOpcode.Prefetch, HlOpcode.Asm: 3;
			case HlOpcode.Call2, HlOpcode.EnumField: 4;
			case HlOpcode.Call3: 5;
			case HlOpcode.Call4: 6;
			case HlOpcode.CallN, HlOpcode.CallMethod, HlOpcode.CallThis, HlOpcode.CallClosure,
				HlOpcode.MakeEnum: VARIABLE_ARITY;
			case HlOpcode.Switch: SWITCH_ARITY;
			default: UNSUPPORTED;
		}

	/** The VM's name of an opcode (`OMov`), or null for a number past the table. */
	public static function name(opcode:Int):Null<String>
		return opcode >= 0 && opcode < NAMES.length ? NAMES[opcode] : null;

	/** The opcode names in number order, as opcodes.h lists them. */
	static final NAMES = [
		"OMov", "OInt", "OFloat", "OBool", "OBytes", "OString", "ONull", "OAdd", "OSub", "OMul", "OSDiv", "OUDiv",
		"OSMod", "OUMod", "OShl", "OSShr", "OUShr", "OAnd", "OOr", "OXor", "ONeg", "ONot", "OIncr", "ODecr", "OCall0",
		"OCall1", "OCall2", "OCall3", "OCall4", "OCallN", "OCallMethod", "OCallThis", "OCallClosure", "OStaticClosure",
		"OInstanceClosure", "OVirtualClosure", "OGetGlobal", "OSetGlobal", "OField", "OSetField", "OGetThis",
		"OSetThis", "ODynGet", "ODynSet", "OJTrue", "OJFalse", "OJNull", "OJNotNull", "OJSLt", "OJSGte", "OJSGt",
		"OJSLte", "OJULt", "OJUGte", "OJNotLt", "OJNotGte", "OJEq", "OJNotEq", "OJAlways", "OToDyn", "OToSFloat",
		"OToUFloat", "OToInt", "OSafeCast", "OUnsafeCast", "OToVirtual", "OLabel", "ORet", "OThrow", "ORethrow",
		"OSwitch", "ONullCheck", "OTrap", "OEndTrap", "OGetI8", "OGetI16", "OGetMem", "OGetArray", "OSetI8", "OSetI16",
		"OSetMem", "OSetArray", "ONew", "OArraySize", "OType", "OGetType", "OGetTID", "ORef", "OUnref", "OSetref",
		"OMakeEnum", "OEnumAlloc", "OEnumIndex", "OEnumField", "OSetEnumField", "OAssert", "ORefData", "ORefOffset",
		"ONop", "OPrefetch", "OAsm", "OCatch", "OCleanupTrap", "OEndCleanupTrap"
	];

	public static function validate(opcode:Int, operands:Array<Int>):Void {
		var expected = arity(opcode);
		if (expected == SWITCH_ARITY) {
			if (operands.length < 3 || operands[1] < 1 || operands.length != operands[1] + 3)
				throw new InternalError('Invalid switch operands');
			for (index in 2...operands.length - 1)
				if (operands[index] < 0)
					throw new InternalError('A switch target is before the switch');
			return;
		}
		if (expected == UNSUPPORTED)
			throw new InternalError('Unsupported patch opcode $opcode');
		if (expected == VARIABLE_ARITY) {
			if (operands.length <= VARIABLE_COUNT_OPERAND)
				throw new InternalError('Missing variable operand count for opcode $opcode');
			var count = operands[VARIABLE_COUNT_OPERAND];
			if (count < 0 || count > 0x1000000 || operands.length != VARIABLE_COUNT_OPERAND + 1 + count)
				throw new InternalError('Invalid variable operands for opcode $opcode');
		} else if (operands.length != expected)
			throw new InternalError('Opcode $opcode expects $expected operands, got ${operands.length}');
	}
}
