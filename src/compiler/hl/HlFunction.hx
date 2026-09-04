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

class HlInstruction {
    public final opcode:HlOpcode;
    public final operands:Array<Int>;

    public function new(opcode:HlOpcode, operands:Array<Int>) {
        this.opcode = opcode;
        this.operands = operands;
    }
}
