package compiler.ir;

import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;

class IrFunction {
    public final name:String;
    public final arguments:Array<IrValue>;
    public final result:IrType;
    public final instructions:Array<IrInstruction>;

    public function new(name:String, arguments:Array<IrValue>, result:IrType, instructions:Array<IrInstruction>) {
        this.name = name;
        this.arguments = arguments;
        this.result = result;
        this.instructions = instructions;
    }
}
