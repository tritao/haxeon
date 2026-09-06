package compiler.ir;

import compiler.ir.SourceProvenance.Located;

/** Backend-oriented value types carried by the SSA intermediate representation. */
enum IrType {
	Void;
	I32;
	Bool;
	F64;
	Bytes;
	Dyn;
	TypeRef;
	Array(element:IrType);
	Enum(name:String);
	Obj(name:String);
	Abstract(name:String);
	Virtual(name:String);
	Function(arguments:Array<IrType>, result:IrType);
}

/** Immutable SSA definition with a function-local numeric identity. */
class IrValue {
	public final id:Int;
	public final name:String;
	public final type:IrType;

	public function new(id, name, type) {
		this.id = id;
		this.name = name;
		this.type = type;
	}
}

/** Value contributed by one predecessor to an SSA phi definition. */
typedef IrPhiInput = {final block:Int; final value:IrValue;}

/** Typed SSA operations independent of HashLink register and symbol indices. */
enum IrInstruction {
	Phi(output:IrValue, inputs:Array<IrPhiInput>);
	ConstVoid(output:IrValue);
	ConstInt(output:IrValue, value:Int);
	ConstFloat(output:IrValue, value:Float);
	ConstString(output:IrValue, value:String);
	ConstBool(output:IrValue, value:Bool);
	ConstNull(output:IrValue);
	TypeValue(output:IrValue, type:IrType);
	ToDyn(output:IrValue, value:IrValue);
	SafeCast(output:IrValue, value:IrValue);
	BeginTry(catchBlock:Int, afterBlock:Int);
	EndTry;
	Catch(output:IrValue);
	GlobalGet(output:IrValue, name:String);
	GlobalSet(name:String, value:IrValue);
	Add(output:IrValue, left:IrValue, right:IrValue);
	Sub(output:IrValue, left:IrValue, right:IrValue);
	Mul(output:IrValue, left:IrValue, right:IrValue);
	Div(output:IrValue, left:IrValue, right:IrValue);
	Mod(output:IrValue, left:IrValue, right:IrValue);
	BitAnd(output:IrValue, left:IrValue, right:IrValue);
	BitXor(output:IrValue, left:IrValue, right:IrValue);
	BitOr(output:IrValue, left:IrValue, right:IrValue);
	ShiftLeft(output:IrValue, left:IrValue, right:IrValue);
	ShiftRight(output:IrValue, left:IrValue, right:IrValue);
	UnsignedShiftRight(output:IrValue, left:IrValue, right:IrValue);
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
	MakeEnum(output:IrValue, typeName:String, constructor:Int, arguments:Array<IrValue>);
	EnumIndex(output:IrValue, value:IrValue);
	EnumField(output:IrValue, value:IrValue, constructor:Int, field:Int);
}

/** Mandatory control transfer ending an SSA basic block. */
enum IrTerminator {
	Return(value:IrValue);
	Throw(value:IrValue);
	Rethrow(value:IrValue);
	Jump(target:Int);
	Branch(condition:IrValue, whenTrue:Int, whenFalse:Int);
}

/** SSA basic block identified independently of its position in the block array. */
class IrBlock {
	public final id:Int;
	public final instructions:Array<Located<IrInstruction>> = [];
	public var terminator:Null<Located<IrTerminator>>;

	public function new(id)
		this.id = id;
}

/** Runtime-native function required by an IR program. */
typedef IrNative = {
	final name:String;
	final library:String;
	final symbol:String;
	final arguments:Array<IrType>;
	final result:IrType;
}

/** Runtime-visible field in an IR object layout. */
typedef IrObjectField = {final name:String; final type:IrType;}

/** Method name and implementing function attached to an IR object. */
typedef IrObjectMethod = {final name:String; final functionName:String;}

/** Object layout and dispatch metadata required by backend lowering. */
typedef IrObject = {final name:String; final base:Null<String>; final interfaces:Array<String>; final fields:Array<IrObjectField>; final methods:Array<IrObjectMethod>;}

/** Callable contract required by an IR interface. */
typedef IrInterfaceMethod = {final name:String; final arguments:Array<IrType>; final result:IrType;}

/** Interface inheritance and method contracts required by backend lowering. */
typedef IrInterface = {final name:String; final bases:Array<String>; final methods:Array<IrInterfaceMethod>;}

/** Ordered payload types of one IR enum constructor. */
typedef IrEnumCase = {final name:String; final params:Array<IrType>;}

/** Enum layout required by backend lowering. */
typedef IrEnum = {final name:String; final cases:Array<IrEnumCase>;}

/** Module-level storage slot required by an IR program. */
typedef IrStaticField = {final name:String; final type:IrType;}

/** Complete register-independent program assembled into a HashLink module. */
class IrProgram {
	public var natives:Array<IrNative> = [];
	public var functions:Array<IrFunction> = [];
	public var objects:Array<IrObject> = [];
	public var interfaces:Array<IrInterface> = [];
	public var enums:Array<IrEnum> = [];
	public var staticFields:Array<IrStaticField> = [];
	public var entryPoint:String;

	public function new(entryPoint:String)
		this.entryPoint = entryPoint;
}
