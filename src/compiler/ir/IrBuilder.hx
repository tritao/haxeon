package compiler.ir;

import compiler.ir.Ir;

class IrBuilder {
    public final blocks:Array<IrBlock> = [];
    public final arguments:Array<IrValue> = [];
    var current:IrBlock;
    var nextValue:Int = 0;

    public function new() current = createBlock();

    public function argument(name:String, type:IrType):IrValue {
        var value = new IrValue(nextValue++, name, type); arguments.push(value); return value;
    }
    public function constInt(value:Int):IrValue { var out=temporary(I32); emit(ConstInt(out,value)); return out; }
    public function add(a:IrValue,b:IrValue):IrValue { var out=temporary(I32); emit(Add(out,a,b)); return out; }
    public function sub(a:IrValue,b:IrValue):IrValue { var out=temporary(I32); emit(Sub(out,a,b)); return out; }
    public function less(a:IrValue,b:IrValue):IrValue return compare(a,b,0);
    public function lessEqual(a:IrValue,b:IrValue):IrValue return compare(a,b,1);
    public function equal(a:IrValue,b:IrValue):IrValue return compare(a,b,2);
    function compare(a:IrValue,b:IrValue,op:Int):IrValue { var out=temporary(Bool); emit(switch op {case 0:Less(out,a,b);case 1:LessEqual(out,a,b);default:Equal(out,a,b);}); return out; }
    public function call(name:String,args:Array<IrValue>,result:IrType):IrValue { var out=temporary(result); emit(Call(out,name,args)); return out; }

    public function createBlock():IrBlock { var block=new IrBlock(blocks.length); blocks.push(block); return block; }
    public function select(block:IrBlock):Void current = block;
    public function terminate(value:IrTerminator):Void {
        if (current.terminator != null) throw 'IR block ${current.id} already has a terminator';
        current.terminator = value;
    }
    public function isTerminated():Bool return current.terminator != null;
    public function returnValue(value:IrValue):Void terminate(Return(value));
    public function jump(target:IrBlock):Void terminate(Jump(target.id));
    public function branch(condition:IrValue, yes:IrBlock, no:IrBlock):Void terminate(Branch(condition, yes.id, no.id));
    function emit(instruction:IrInstruction):Void { if (isTerminated()) throw "Cannot emit after terminator"; current.instructions.push(instruction); }
    function temporary(type:IrType):IrValue return new IrValue(nextValue++, 'v$nextValue', type);
}
