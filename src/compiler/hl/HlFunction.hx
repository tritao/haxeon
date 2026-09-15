package compiler.hl;

/** HashLink debugger location corresponding exactly to one encoded opcode. */
typedef HlDebugLocation = {
	final path:String;
	final line:Int;
	final column:Int;
	final endLine:Int;
	final endColumn:Int;
	final sourceHash:Int;
	final start:Null<Int>;
	final end:Null<Int>;
	final flags:Int;
}

/** HashLink debugger binding at an encoded opcode, or -1 for an argument. */
typedef HlDebugAssignment = {
	final name:Int;
	final position:Int;
	final scopeEnd:Int;
}

/** HashLink bytecode function after register allocation and symbol resolution. */
class HlFunction {
	public final type:Int;
	public final functionIndex:Int;
	public final registers:Array<Int>;
	public final opcodes:Array<HlInstruction>;
	public final debugLocations:Array<HlDebugLocation>;
	public final debugAssignments:Array<HlDebugAssignment>;

	public function new(type:Int, functionIndex:Int, registers:Array<Int>, opcodes:Array<HlInstruction>, ?debugLocations:Array<HlDebugLocation>,
			?debugAssignments:Array<HlDebugAssignment>) {
		this.type = type;
		this.functionIndex = functionIndex;
		this.registers = registers;
		this.opcodes = opcodes;
		this.debugLocations = debugLocations == null ? [] : debugLocations;
		this.debugAssignments = debugAssignments == null ? [] : debugAssignments;
	}
}

/** Symbolic HashLink instruction used before labels become relative offsets. */
enum HlInstruction {
	Move(destination:Int, source:Int);
	LoadInt(destination:Int, constant:Int);
	LoadFloat(destination:Int, constant:Int);
	LoadString(destination:Int, constant:Int);
	LoadBytes(destination:Int, constant:Int);
	LoadBool(destination:Int, value:Bool);
	LoadNull(destination:Int);
	LoadType(destination:Int, type:Int);
	ToDyn(destination:Int, source:Int);
	ToSFloat(destination:Int, source:Int);
	ToUFloat(destination:Int, source:Int);
	ToInt(destination:Int, source:Int);
	SafeCast(destination:Int, source:Int);
	UnsafeCast(destination:Int, source:Int);
	Trap(destination:Int, target:String);
	EndTrap(destination:Int);
	GlobalGet(destination:Int, global:Int);
	GlobalSet(global:Int, source:Int);
	ThisGet(destination:Int, field:Int);
	ThisSet(field:Int, source:Int);
	Add(destination:Int, left:Int, right:Int);
	Sub(destination:Int, left:Int, right:Int);
	Mul(destination:Int, left:Int, right:Int);
	Div(destination:Int, left:Int, right:Int);
	UnsignedDiv(destination:Int, left:Int, right:Int);
	Mod(destination:Int, left:Int, right:Int);
	UnsignedMod(destination:Int, left:Int, right:Int);
	BitAnd(destination:Int, left:Int, right:Int);
	BitXor(destination:Int, left:Int, right:Int);
	BitOr(destination:Int, left:Int, right:Int);
	ShiftLeft(destination:Int, left:Int, right:Int);
	ShiftRight(destination:Int, left:Int, right:Int);
	UnsignedShiftRight(destination:Int, left:Int, right:Int);
	Negate(destination:Int, source:Int);
	BitNot(destination:Int, source:Int);
	Increment(destination:Int);
	Decrement(destination:Int);
	Call0(destination:Int, functionIndex:Int);
	Call1(destination:Int, functionIndex:Int, argument:Int);
	Call2(destination:Int, functionIndex:Int, argument1:Int, argument2:Int);
	Call3(destination:Int, functionIndex:Int, argument1:Int, argument2:Int, argument3:Int);
	Call4(destination:Int, functionIndex:Int, argument1:Int, argument2:Int, argument3:Int, argument4:Int);
	CallN(destination:Int, functionIndex:Int, arguments:Array<Int>);
	StaticClosure(destination:Int, functionIndex:Int);
	InstanceClosure(destination:Int, functionIndex:Int, receiver:Int);
	VirtualClosure(destination:Int, object:Int, method:Int);
	CallClosure(destination:Int, closure:Int, arguments:Array<Int>);
	ToVirtual(destination:Int, source:Int);
	CallMethod(destination:Int, method:Int, arguments:Array<Int>);
	ThisCall(destination:Int, method:Int, arguments:Array<Int>);
	New(destination:Int, type:Int, extra:Int);
	FieldGet(destination:Int, object:Int, field:Int);
	FieldSet(object:Int, field:Int, source:Int);
	ArrayGet(destination:Int, array:Int, index:Int);
	ArraySet(array:Int, index:Int, source:Int);
	GetI8(destination:Int, pointer:Int, offset:Int);
	GetI16(destination:Int, pointer:Int, offset:Int);
	GetMem(destination:Int, pointer:Int, offset:Int);
	SetI8(pointer:Int, offset:Int, source:Int);
	SetI16(pointer:Int, offset:Int, source:Int);
	SetMem(pointer:Int, offset:Int, source:Int);
	ArraySize(destination:Int, array:Int);
	MakeEnum(destination:Int, constructor:Int, arguments:Array<Int>);
	EnumAlloc(destination:Int, constructor:Int);
	EnumIndex(destination:Int, value:Int);
	EnumField(destination:Int, value:Int, constructor:Int, field:Int);
	JumpFalse(condition:Int, target:String);
	JumpNull(value:Int, target:String);
	JumpNotNull(value:Int, target:String);
	JumpSignedLessOrEqual(left:Int, right:Int, target:String);
	JumpSignedLess(left:Int, right:Int, target:String);
	JumpSignedGreaterOrEqual(left:Int, right:Int, target:String);
	JumpSignedGreater(left:Int, right:Int, target:String);
	JumpUnsignedLess(left:Int, right:Int, target:String);
	JumpUnsignedGreaterOrEqual(left:Int, right:Int, target:String);
	JumpNotLess(left:Int, right:Int, target:String);
	JumpNotGreater(left:Int, right:Int, target:String);
	JumpEqual(left:Int, right:Int, target:String);
	JumpNotEqual(left:Int, right:Int, target:String);
	JumpTrue(condition:Int, target:String);
	Jump(target:String);
	Label(name:String);
	Return(register:Int);
	Throw(register:Int);
	Rethrow(register:Int);
}
