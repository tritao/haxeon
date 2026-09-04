package compiler.ir;

enum IrType {
    Void;
    I32;
}

class IrValue {
    public final name:String;
    public final type:IrType;

    public function new(name:String, type:IrType) {
        this.name = name;
        this.type = type;
    }
}

enum IrInstruction {
    ConstInt(output:IrValue, value:Int);
    Add(output:IrValue, left:IrValue, right:IrValue);
    Sub(output:IrValue, left:IrValue, right:IrValue);
    Call(output:IrValue, functionName:String, arguments:Array<IrValue>);
    BranchLessOrEqual(left:IrValue, right:IrValue, target:String);
    Jump(target:String);
    Label(name:String);
    Return(value:IrValue);
}

typedef IrNative = {
    final name:String;
    final library:String;
    final symbol:String;
    final arguments:Array<IrType>;
    final result:IrType;
}

class IrProgram {
    public var natives:Array<IrNative> = [];
    public var functions:Array<IrFunction> = [];
    public var entryPoint:String;

    public function new(entryPoint:String) {
        this.entryPoint = entryPoint;
    }
}
