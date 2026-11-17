import compiler.hl.HlOpcode;
import compiler.hl.HlOpcodeSchema;
import sys.io.File;

/**
 * The opcode tables agree with the VM they are written for: every opcode of vendor/hashlink/src/opcodes.h has its number in
 * HlOpcode, its name in HlOpcodeSchema.name, and HlOpcodeSchema.decodeArity reads as many operands as the loader does
 * (`hl_op_nargs` in code.c). The opcodes this compiler emits are held to the same count by HlOpcodeSchema.arity. A change on
 * either side that the other does not follow fails here, not as a miscompiled or unreadable module.
 */
class HlOpcodeTableMain {
	static function main():Void {
		var text = File.getContent("vendor/hashlink/src/opcodes.h");
		text = text.substring(text.indexOf("\nOP_BEGIN"), text.indexOf("\nOP_END"));
		var entry = ~/OP\((\w+),\s*(\w+),\s*(\w+),\s*(\w+)\)/, numbers = numbersByName(), index = 0, checked = 0;
		while (entry.match(text)) {
			var name = entry.matched(1), first = entry.matched(2), second = entry.matched(3), third = entry.matched(4);
			text = entry.matchedRight();
			if (name == "OLast")
				break;
			var short = name.substr(1);
			expect(numbers.exists(short), 'HlOpcode has no $short');
			expect(numbers.get(short) == index,
				'HlOpcode.$short is ${numbers.get(short)}, opcodes.h numbers it $index');
			expect(HlOpcodeSchema.name(index) == name,
				'HlOpcodeSchema.name($index) is ${HlOpcodeSchema.name(index)}, not $name');
			var expected = if (name == "OSwitch") HlOpcodeSchema.SWITCH_ARITY else if (second == "AR")
				(third == "VAR_ARGS" ? HlOpcodeSchema.VARIABLE_ARITY : Std.parseInt(third)) else if (third != "X") 3
				else if (second != "X") 2 else if (first != "X") 1 else 0;
			expect(HlOpcodeSchema.decodeArity(index) == expected,
				'$name: decodeArity is ${HlOpcodeSchema.decodeArity(index)}, the loader reads $expected');
			var emitted = HlOpcodeSchema.arity(index);
			expect(emitted == HlOpcodeSchema.UNSUPPORTED || emitted == expected,
				'$name: arity $emitted differs from the loader\'s $expected');
			index++;
			checked++;
		}
		expect(checked == Lambda.count(numbers), 'opcodes.h lists $checked opcodes, HlOpcode ${Lambda.count(numbers)}');
		expect(HlOpcodeSchema.name(index) == null, "no name past the table");
		Sys.println('PASS: HlOpcode and HlOpcodeSchema agree with opcodes.h on $checked opcodes');
	}

	static function numbersByName():Map<String, Int>
		return [
			"Mov" => HlOpcode.Mov,
			"Int" => HlOpcode.Int,
			"Float" => HlOpcode.Float,
			"Bool" => HlOpcode.Bool,
			"Bytes" => HlOpcode.Bytes,
			"String" => HlOpcode.String,
			"Null" => HlOpcode.Null,
			"Add" => HlOpcode.Add,
			"Sub" => HlOpcode.Sub,
			"Mul" => HlOpcode.Mul,
			"SDiv" => HlOpcode.SDiv,
			"UDiv" => HlOpcode.UDiv,
			"SMod" => HlOpcode.SMod,
			"UMod" => HlOpcode.UMod,
			"Shl" => HlOpcode.Shl,
			"SShr" => HlOpcode.SShr,
			"UShr" => HlOpcode.UShr,
			"And" => HlOpcode.And,
			"Or" => HlOpcode.Or,
			"Xor" => HlOpcode.Xor,
			"Neg" => HlOpcode.Neg,
			"Not" => HlOpcode.Not,
			"Incr" => HlOpcode.Incr,
			"Decr" => HlOpcode.Decr,
			"Call0" => HlOpcode.Call0,
			"Call1" => HlOpcode.Call1,
			"Call2" => HlOpcode.Call2,
			"Call3" => HlOpcode.Call3,
			"Call4" => HlOpcode.Call4,
			"CallN" => HlOpcode.CallN,
			"CallMethod" => HlOpcode.CallMethod,
			"CallThis" => HlOpcode.CallThis,
			"CallClosure" => HlOpcode.CallClosure,
			"StaticClosure" => HlOpcode.StaticClosure,
			"InstanceClosure" => HlOpcode.InstanceClosure,
			"VirtualClosure" => HlOpcode.VirtualClosure,
			"GetGlobal" => HlOpcode.GetGlobal,
			"SetGlobal" => HlOpcode.SetGlobal,
			"Field" => HlOpcode.Field,
			"SetField" => HlOpcode.SetField,
			"GetThis" => HlOpcode.GetThis,
			"SetThis" => HlOpcode.SetThis,
			"DynGet" => HlOpcode.DynGet,
			"DynSet" => HlOpcode.DynSet,
			"JTrue" => HlOpcode.JTrue,
			"JFalse" => HlOpcode.JFalse,
			"JNull" => HlOpcode.JNull,
			"JNotNull" => HlOpcode.JNotNull,
			"JSLt" => HlOpcode.JSLt,
			"JSGte" => HlOpcode.JSGte,
			"JSGt" => HlOpcode.JSGt,
			"JSLte" => HlOpcode.JSLte,
			"JULt" => HlOpcode.JULt,
			"JUGte" => HlOpcode.JUGte,
			"JNotLt" => HlOpcode.JNotLt,
			"JNotGte" => HlOpcode.JNotGte,
			"JEq" => HlOpcode.JEq,
			"JNotEq" => HlOpcode.JNotEq,
			"JAlways" => HlOpcode.JAlways,
			"ToDyn" => HlOpcode.ToDyn,
			"ToSFloat" => HlOpcode.ToSFloat,
			"ToUFloat" => HlOpcode.ToUFloat,
			"ToInt" => HlOpcode.ToInt,
			"SafeCast" => HlOpcode.SafeCast,
			"UnsafeCast" => HlOpcode.UnsafeCast,
			"ToVirtual" => HlOpcode.ToVirtual,
			"Label" => HlOpcode.Label,
			"Ret" => HlOpcode.Ret,
			"Throw" => HlOpcode.Throw,
			"Rethrow" => HlOpcode.Rethrow,
			"Switch" => HlOpcode.Switch,
			"NullCheck" => HlOpcode.NullCheck,
			"Trap" => HlOpcode.Trap,
			"EndTrap" => HlOpcode.EndTrap,
			"GetI8" => HlOpcode.GetI8,
			"GetI16" => HlOpcode.GetI16,
			"GetMem" => HlOpcode.GetMem,
			"GetArray" => HlOpcode.GetArray,
			"SetI8" => HlOpcode.SetI8,
			"SetI16" => HlOpcode.SetI16,
			"SetMem" => HlOpcode.SetMem,
			"SetArray" => HlOpcode.SetArray,
			"New" => HlOpcode.New,
			"ArraySize" => HlOpcode.ArraySize,
			"Type" => HlOpcode.Type,
			"GetType" => HlOpcode.GetType,
			"GetTID" => HlOpcode.GetTID,
			"Ref" => HlOpcode.Ref,
			"Unref" => HlOpcode.Unref,
			"Setref" => HlOpcode.Setref,
			"MakeEnum" => HlOpcode.MakeEnum,
			"EnumAlloc" => HlOpcode.EnumAlloc,
			"EnumIndex" => HlOpcode.EnumIndex,
			"EnumField" => HlOpcode.EnumField,
			"SetEnumField" => HlOpcode.SetEnumField,
			"Assert" => HlOpcode.Assert,
			"RefData" => HlOpcode.RefData,
			"RefOffset" => HlOpcode.RefOffset,
			"Nop" => HlOpcode.Nop,
			"Prefetch" => HlOpcode.Prefetch,
			"Asm" => HlOpcode.Asm,
			"Catch" => HlOpcode.Catch,
			"CleanupTrap" => HlOpcode.CleanupTrap,
			"EndCleanupTrap" => HlOpcode.EndCleanupTrap
		];

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
