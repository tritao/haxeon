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
    LoadInt(destination:Int, constant:Int);
    Add(destination:Int, left:Int, right:Int);
    Sub(destination:Int, left:Int, right:Int);
    Call0(destination:Int, functionIndex:Int);
    Call1(destination:Int, functionIndex:Int, argument:Int);
    Call2(destination:Int, functionIndex:Int, argument1:Int, argument2:Int);
    JumpSignedLessOrEqual(left:Int, right:Int, target:String);
    Jump(target:String);
    Label(name:String);
    Return(register:Int);
}
