package compiler.hl;

class HlFunction {
	public final type:Int;
	public final functionIndex:Int;
	public final registers:Array<Int>;
	public final opcodes:Array<HlInstruction>;

	public function new(type:Int, functionIndex:Int, registers:Array<Int>, opcodes:Array<HlInstruction>) {
		this.type = type;
		this.functionIndex = functionIndex;
		this.registers = registers;
		this.opcodes = opcodes;
	}
}

enum HlInstruction {
	Move(destination:Int, source:Int);
	LoadInt(destination:Int, constant:Int);
	LoadFloat(destination:Int, constant:Int);
	LoadString(destination:Int, constant:Int);
	LoadBool(destination:Int, value:Bool);
	LoadNull(destination:Int);
	ToDyn(destination:Int, source:Int);
	Trap(destination:Int, target:String);
	EndTrap(destination:Int);
	GlobalGet(destination:Int, global:Int);
	GlobalSet(global:Int, source:Int);
	Add(destination:Int, left:Int, right:Int);
	Sub(destination:Int, left:Int, right:Int);
	Mul(destination:Int, left:Int, right:Int);
	Div(destination:Int, left:Int, right:Int);
	Mod(destination:Int, left:Int, right:Int);
	Call0(destination:Int, functionIndex:Int);
	Call1(destination:Int, functionIndex:Int, argument:Int);
	Call2(destination:Int, functionIndex:Int, argument1:Int, argument2:Int);
	CallN(destination:Int, functionIndex:Int, arguments:Array<Int>);
	StaticClosure(destination:Int, functionIndex:Int);
	InstanceClosure(destination:Int, functionIndex:Int, receiver:Int);
	CallClosure(destination:Int, closure:Int, arguments:Array<Int>);
	ToVirtual(destination:Int, source:Int);
	CallMethod(destination:Int, method:Int, arguments:Array<Int>);
	New(destination:Int, type:Int, extra:Int);
	FieldGet(destination:Int, object:Int, field:Int);
	FieldSet(object:Int, field:Int, source:Int);
	ArrayGet(destination:Int, array:Int, index:Int);
	ArraySet(array:Int, index:Int, source:Int);
	ArraySize(destination:Int, array:Int);
	MakeEnum(destination:Int, constructor:Int, arguments:Array<Int>);
	EnumIndex(destination:Int, value:Int);
	EnumField(destination:Int, value:Int, constructor:Int, field:Int);
	JumpSignedLessOrEqual(left:Int, right:Int, target:String);
	JumpSignedLess(left:Int, right:Int, target:String);
	JumpEqual(left:Int, right:Int, target:String);
	JumpTrue(condition:Int, target:String);
	Jump(target:String);
	Label(name:String);
	Return(register:Int);
	Throw(register:Int);
}
