package compiler.ir;

import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;

class IrBuilder {
    public final instructions:Array<IrInstruction> = [];
    var nextValue:Int = 0;
    var nextLabel:Int = 0;

    public function new() {}

    public function constInt(value:Int):IrValue {
        var output = temporary(IrType.I32);
        instructions.push(ConstInt(output, value));
        return output;
    }

    public function add(left:IrValue, right:IrValue):IrValue {
        var output = temporary(IrType.I32);
        instructions.push(Add(output, left, right));
        return output;
    }

    public function sub(left:IrValue, right:IrValue):IrValue {
        var output = temporary(IrType.I32);
        instructions.push(Sub(output, left, right));
        return output;
    }

    public function less(left:IrValue, right:IrValue):IrValue return compare(left, right, 0);
    public function lessEqual(left:IrValue, right:IrValue):IrValue return compare(left, right, 1);
    public function equal(left:IrValue, right:IrValue):IrValue return compare(left, right, 2);

    function compare(left:IrValue, right:IrValue, operation:Int):IrValue {
        var output = temporary(IrType.Bool);
        instructions.push(switch operation { case 0: Less(output,left,right); case 1: LessEqual(output,left,right); default: Equal(output,left,right); });
        return output;
    }

    public function call(functionName:String, arguments:Array<IrValue>, result:IrType):IrValue {
        var output = temporary(result);
        instructions.push(Call(output, functionName, arguments));
        return output;
    }

    public function branchLessOrEqual(left:IrValue, right:IrValue, target:String):Void {
        instructions.push(BranchLessOrEqual(left, right, target));
    }

    public function branchTrue(condition:IrValue, target:String):Void instructions.push(BranchTrue(condition, target));

    public function newLabel(?hint:String):String return hint == null ? 'label${nextLabel++}' : hint;

    public function jump(target:String):Void {
        instructions.push(Jump(target));
    }

    public function label(?hint:String):String {
        var name = newLabel(hint);
        instructions.push(Label(name));
        return name;
    }

    public function returnValue(value:IrValue):Void {
        instructions.push(Return(value));
    }

    function temporary(type:IrType):IrValue {
        return new IrValue('t${nextValue++}', type);
    }
}
