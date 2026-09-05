package compiler.ir;

enum IrType {
	Void;
	I32;
	Bool;
	F64;
	Bytes;
	Dyn;
	Array(element:IrType);
	Obj(name:String);
	Abstract(name:String);
	Virtual(name:String);
	Function(arguments:Array<IrType>, result:IrType);
}

abstract ValueId(Int) from Int to Int {}
abstract BlockId(Int) from Int to Int {}

class IrValue {
	public final id:ValueId;
	public final name:String;
	public final type:IrType;

	public function new(id, name, type) {
		this.id = id;
		this.name = name;
		this.type = type;
	}
}

typedef IrPhiInput = {final block:BlockId; final value:IrValue;}

enum IrInstruction {
	Phi(output:IrValue, inputs:Array<IrPhiInput>);
	ConstVoid(output:IrValue);
	ConstInt(output:IrValue, value:Int);
	ConstFloat(output:IrValue, value:Float);
	ConstString(output:IrValue, value:String);
	ConstBool(output:IrValue, value:Bool);
	ConstNull(output:IrValue);
	Add(output:IrValue, left:IrValue, right:IrValue);
	Sub(output:IrValue, left:IrValue, right:IrValue);
	Mul(output:IrValue, left:IrValue, right:IrValue);
	Div(output:IrValue, left:IrValue, right:IrValue);
	Less(output:IrValue, left:IrValue, right:IrValue);
	LessEqual(output:IrValue, left:IrValue, right:IrValue);
	Equal(output:IrValue, left:IrValue, right:IrValue);
	Call(output:IrValue, functionName:String, arguments:Array<IrValue>);
	StaticClosure(output:IrValue, functionName:String);
	InstanceClosure(output:IrValue, functionName:String, receiver:IrValue);
	CallClosure(output:IrValue, closure:IrValue, arguments:Array<IrValue>);
	ToVirtual(output:IrValue, value:IrValue);
	MethodCall(output:IrValue, object:IrValue, methodName:String, arguments:Array<IrValue>);
	NewObject(output:IrValue, typeName:String);
	FieldGet(output:IrValue, object:IrValue, fieldName:String);
	FieldSet(object:IrValue, fieldName:String, value:IrValue);
	ArrayGet(output:IrValue, array:IrValue, index:IrValue);
	ArraySet(array:IrValue, index:IrValue, value:IrValue);
	ArraySize(output:IrValue, array:IrValue);
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

	public function new(id)
		this.id = id;
}

typedef IrNative = {
	final name:String;
	final library:String;
	final symbol:String;
	final arguments:Array<IrType>;
	final result:IrType;
}

typedef IrObjectField = {final name:String; final type:IrType;}
typedef IrObjectMethod = {final name:String; final functionName:String;}
typedef IrObject = {final name:String; final base:Null<String>; final interfaces:Array<String>; final fields:Array<IrObjectField>; final methods:Array<IrObjectMethod>;}
typedef IrInterfaceMethod = {final name:String; final arguments:Array<IrType>; final result:IrType;}
typedef IrInterface = {final name:String; final bases:Array<String>; final methods:Array<IrInterfaceMethod>;}

class IrProgram {
	public var natives:Array<IrNative> = [];
	public var functions:Array<IrFunction> = [];
	public var objects:Array<IrObject> = [];
	public var interfaces:Array<IrInterface> = [];
	public var entryPoint:String;

	public function new(entryPoint:String)
		this.entryPoint = entryPoint;
}
