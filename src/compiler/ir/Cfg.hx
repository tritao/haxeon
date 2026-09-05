package compiler.ir;

import compiler.ir.Ir.IrType;

abstract CfgValueId(Int) from Int to Int {}

class CfgValue {
	public final id:CfgValueId;
	public final type:IrType;

	public function new(id, type) {
		this.id = id;
		this.type = type;
	}
}

enum CfgInstruction {
	ConstVoid(output:CfgValue);
	ConstInt(output:CfgValue, value:Int);
	ConstFloat(output:CfgValue, value:Float);
	ConstString(output:CfgValue, value:String);
	LoadLocal(output:CfgValue, name:String);
	StoreLocal(name:String, value:CfgValue);
	Add(output:CfgValue, left:CfgValue, right:CfgValue);
	Sub(output:CfgValue, left:CfgValue, right:CfgValue);
	Mul(output:CfgValue, left:CfgValue, right:CfgValue);
	Div(output:CfgValue, left:CfgValue, right:CfgValue);
	Less(output:CfgValue, left:CfgValue, right:CfgValue);
	LessEqual(output:CfgValue, left:CfgValue, right:CfgValue);
	Equal(output:CfgValue, left:CfgValue, right:CfgValue);
	Call(output:CfgValue, functionName:String, arguments:Array<CfgValue>);
	StaticClosure(output:CfgValue, functionName:String);
	InstanceClosure(output:CfgValue, functionName:String, receiver:CfgValue);
	CallClosure(output:CfgValue, closure:CfgValue, arguments:Array<CfgValue>);
	MethodCall(output:CfgValue, object:CfgValue, methodName:String, arguments:Array<CfgValue>);
	NewObject(output:CfgValue, typeName:String);
	FieldGet(output:CfgValue, object:CfgValue, fieldName:String);
	FieldSet(object:CfgValue, fieldName:String, value:CfgValue);
	ArrayGet(output:CfgValue, array:CfgValue, index:CfgValue);
	ArraySet(array:CfgValue, index:CfgValue, value:CfgValue);
	ArraySize(output:CfgValue, array:CfgValue);
}

enum CfgTerminator {
	Return(value:CfgValue);
	Jump(target:Int);
	Branch(condition:CfgValue, whenTrue:Int, whenFalse:Int);
}

class CfgBlock {
	public final id:Int;
	public final instructions:Array<CfgInstruction> = [];
	public var terminator:Null<CfgTerminator>;

	public function new(id)
		this.id = id;
}

typedef CfgArgument = {final name:String; final type:IrType;}

class CfgFunction {
	public final name:String;
	public final arguments:Array<CfgArgument>;
	public final result:IrType;
	public final blocks:Array<CfgBlock>;
	public final localTypes:Map<String, IrType>;

	public function new(name, arguments, result, blocks, localTypes) {
		this.name = name;
		this.arguments = arguments;
		this.result = result;
		this.blocks = blocks;
		this.localTypes = localTypes;
	}
}
