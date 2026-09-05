package compiler.hl;

/** Opcode numbers are ABI: their order follows HashLink's src/opcodes.h. */
enum abstract HlOpcode(Int) from Int to Int {
	var Mov = 0;
	var Int = 1;
	var Float = 2;
	var Bool = 3;
	var String = 5;
	var Null = 6;
	var Add = 7;
	var Sub = 8;
	var Mul = 9;
	var SDiv = 10;
	var SMod = 11;
	var Label = 66;
	var Call0 = 24;
	var Call1 = 25;
	var Call2 = 26;
	var CallN = 29;
	var CallClosure = 32;
	var StaticClosure = 33;
	var InstanceClosure = 34;
	var GetGlobal = 36;
	var SetGlobal = 37;
	var CallMethod = 30;
	var Field = 38;
	var SetField = 39;
	var GetArray = 77;
	var SetArray = 81;
	var New = 82;
	var ArraySize = 83;
	var MakeEnum = 90;
	var EnumAlloc = 91;
	var EnumIndex = 92;
	var EnumField = 93;
	var JTrue = 44;
	var JSLt = 48;
	var JSLte = 51;
	var JEq = 56;
	var JAlways = 58;
	var Ret = 67;
	var ToDyn = 59;
	var Throw = 68;
	var Trap = 72;
	var EndTrap = 73;
	var ToVirtual = 65;
}
