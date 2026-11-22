package compiler.ir.model;

/**
 * The operation of an `IrBody` row: one per `IrInstruction` kind, one per `IrIntrinsic` operation, and one per `IrTerminator`
 * kind, which come last so a row is a terminator when its opcode is at least `Unreachable`. What each row's auxiliary field holds
 * is listed at `IrBody`.
 */
enum abstract IrOpcode(Int) from Int to Int {
	var Phi = 0;
	var ConstVoid = 1;
	var ConstInt = 2;
	var ConstFloat = 3;
	var ConstString = 4;
	var StaticDataAddress = 5;
	var PointerOffset = 6;
	var MemoryLoad = 7;
	var MemoryStore = 8;
	var ConstBool = 9;
	var ConstNull = 10;
	var TypeValue = 11;
	var ToDyn = 12;
	var IntToFloat = 13;
	var IntToInt64 = 14;
	var FloatToInt = 15;
	var FloatToFloat = 16;
	var SafeCast = 17;
	var BeginTry = 18;
	var EndTry = 19;
	var Catch = 20;
	var GlobalGet = 21;
	var GlobalSet = 22;
	var Add = 23;
	var Sub = 24;
	var Mul = 25;
	var Div = 26;
	var Mod = 27;
	var BitAnd = 28;
	var BitXor = 29;
	var BitOr = 30;
	var ShiftLeft = 31;
	var ShiftRight = 32;
	var UnsignedShiftRight = 33;
	var Less = 34;
	var LessEqual = 35;
	var Equal = 36;
	var Call = 37;
	var CNativeCall = 38;
	var StaticClosure = 39;
	var InstanceClosure = 40;
	var CallClosure = 41;
	var ToVirtual = 42;
	var Upcast = 43;
	var ClassId = 44;
	var MethodCall = 45;
	var NewObject = 46;
	var ValueInit = 47;
	var FieldGet = 48;
	var FieldSet = 49;
	var ArrayGet = 50;
	var ArraySet = 51;
	var ArraySize = 52;
	var IteratorNew = 53;
	var IteratorHasNext = 54;
	var IteratorNext = 55;
	var MakeEnum = 56;
	var EnumIndex = 57;
	var EnumField = 58;
	var EnumDynamicBox = 59;
	var EnumDynamicView = 60;
	var EnumTagBox = 61;
	var EnumTagUnbox = 62;
	var InlineEnumBox = 63;
	var InlineEnumUnbox = 64;
	var Unreachable = 65;
	var Return = 66;
	var Throw = 67;
	var Rethrow = 68;
	var Jump = 69;
	var Branch = 70;
	var Switch = 71;

	/** How many opcodes there are: every opcode is below it, so it sizes a table indexed by opcode. */
	public static inline final COUNT = 72;

	public inline function isTerminator():Bool
		return this >= (Unreachable:Int);
}
