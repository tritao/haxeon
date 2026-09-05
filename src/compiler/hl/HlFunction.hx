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
	Add(destination:Int, left:Int, right:Int);
	Sub(destination:Int, left:Int, right:Int);
	Mul(destination:Int, left:Int, right:Int);
	Div(destination:Int, left:Int, right:Int);
	Call0(destination:Int, functionIndex:Int);
	Call1(destination:Int, functionIndex:Int, argument:Int);
	Call2(destination:Int, functionIndex:Int, argument1:Int, argument2:Int);
	CallN(destination:Int, functionIndex:Int, arguments:Array<Int>);
	StaticClosure(destination:Int, functionIndex:Int);
	InstanceClosure(destination:Int, functionIndex:Int, receiver:Int);
	CallClosure(destination:Int, closure:Int, arguments:Array<Int>);
	CallMethod(destination:Int, method:Int, arguments:Array<Int>);
	New(destination:Int, type:Int, extra:Int);
	FieldGet(destination:Int, object:Int, field:Int);
	FieldSet(object:Int, field:Int, source:Int);
	ArrayGet(destination:Int, array:Int, index:Int);
	ArraySet(array:Int, index:Int, source:Int);
	ArraySize(destination:Int, array:Int);
	JumpSignedLessOrEqual(left:Int, right:Int, target:String);
	JumpSignedLess(left:Int, right:Int, target:String);
	JumpEqual(left:Int, right:Int, target:String);
	JumpTrue(condition:Int, target:String);
	Jump(target:String);
	Label(name:String);
	Return(register:Int);
}
