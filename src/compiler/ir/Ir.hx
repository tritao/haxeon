package compiler.ir;

enum IrType { Void; I32; Bool; F64; Bytes; }
abstract ValueId(Int) from Int to Int {}
abstract BlockId(Int) from Int to Int {}

class IrValue {
    public final id:ValueId;
    public final name:String;
    public final type:IrType;
    public function new(id, name, type) { this.id = id; this.name = name; this.type = type; }
}

typedef IrPhiInput = {final block:BlockId;final value:IrValue;}

enum IrInstruction {
    Phi(output:IrValue,inputs:Array<IrPhiInput>);
    ConstInt(output:IrValue, value:Int);
    ConstFloat(output:IrValue,value:Float);
    ConstString(output:IrValue,value:String);
    Add(output:IrValue, left:IrValue, right:IrValue);
    Sub(output:IrValue, left:IrValue, right:IrValue);
    Mul(output:IrValue,left:IrValue,right:IrValue);
    Div(output:IrValue,left:IrValue,right:IrValue);
    Less(output:IrValue, left:IrValue, right:IrValue);
    LessEqual(output:IrValue, left:IrValue, right:IrValue);
    Equal(output:IrValue, left:IrValue, right:IrValue);
    Call(output:IrValue, functionName:String, arguments:Array<IrValue>);
}

enum IrTerminator {
    Return(value:IrValue);
    Jump(target:BlockId);
    Branch(condition:IrValue, whenTrue:BlockId, whenFalse:BlockId);
}

class IrBlock {
    public final id:BlockId;
    public final instructions:Array<IrInstruction> = [];
    public var terminator:Null<IrTerminator>;
    public function new(id) this.id = id;
}

typedef IrNative = {
    final name:String; final library:String; final symbol:String;
    final arguments:Array<IrType>; final result:IrType;
}

class IrProgram {
    public var natives:Array<IrNative> = [];
    public var functions:Array<IrFunction> = [];
    public var entryPoint:String;
    public function new(entryPoint:String) this.entryPoint = entryPoint;
}
