package compiler.ir.cfg;

import compiler.ir.Ir.IrType;
import compiler.ir.SourceProvenance.Located;

/** Function-local identity for a value in mutable control-flow form. */
abstract CfgValueId(Int) from Int to Int {}

/** Typed value referenced by mutable CFG instructions. */
class CfgValue {
	public final id:CfgValueId;
	public final type:IrType;

	public function new(id, type) {
		this.id = id;
		this.type = type;
	}
}

/**
 * Instruction set used before SSA construction.
 *
 * Explicit local loads and stores are eliminated by {@code SsaBuilder}.
 */
enum CfgInstruction {
	ConstVoid(output:CfgValue);
	ConstInt(output:CfgValue, value:Int);
	ConstFloat(output:CfgValue, value:Float);
	ConstString(output:CfgValue, value:String);
	ConstBool(output:CfgValue, value:Bool);
	ConstNull(output:CfgValue);
	TypeValue(output:CfgValue, type:IrType);
	ToDyn(output:CfgValue, value:CfgValue);
	SafeCast(output:CfgValue, value:CfgValue);
	BeginTry(catchBlock:Int, afterBlock:Int);
	EndTry;
	Catch(output:CfgValue);
	LoadLocal(output:CfgValue, name:String);
	StoreLocal(name:String, value:CfgValue);
	GlobalGet(output:CfgValue, name:String);
	GlobalSet(name:String, value:CfgValue);
	Add(output:CfgValue, left:CfgValue, right:CfgValue);
	Sub(output:CfgValue, left:CfgValue, right:CfgValue);
	Mul(output:CfgValue, left:CfgValue, right:CfgValue);
	Div(output:CfgValue, left:CfgValue, right:CfgValue);
	Mod(output:CfgValue, left:CfgValue, right:CfgValue);
	BitAnd(output:CfgValue, left:CfgValue, right:CfgValue);
	BitXor(output:CfgValue, left:CfgValue, right:CfgValue);
	BitOr(output:CfgValue, left:CfgValue, right:CfgValue);
	ShiftLeft(output:CfgValue, left:CfgValue, right:CfgValue);
	ShiftRight(output:CfgValue, left:CfgValue, right:CfgValue);
	UnsignedShiftRight(output:CfgValue, left:CfgValue, right:CfgValue);
	Less(output:CfgValue, left:CfgValue, right:CfgValue);
	LessEqual(output:CfgValue, left:CfgValue, right:CfgValue);
	Equal(output:CfgValue, left:CfgValue, right:CfgValue);
	Call(output:CfgValue, functionName:String, arguments:Array<CfgValue>);
	StaticClosure(output:CfgValue, functionName:String);
	InstanceClosure(output:CfgValue, functionName:String, receiver:CfgValue);
	CallClosure(output:CfgValue, closure:CfgValue, arguments:Array<CfgValue>);
	ToVirtual(output:CfgValue, value:CfgValue);
	MethodCall(output:CfgValue, object:CfgValue, methodName:String, arguments:Array<CfgValue>);
	NewObject(output:CfgValue, typeName:String);
	FieldGet(output:CfgValue, object:CfgValue, fieldName:String);
	FieldSet(object:CfgValue, fieldName:String, value:CfgValue);
	ArrayGet(output:CfgValue, array:CfgValue, index:CfgValue);
	ArraySet(array:CfgValue, index:CfgValue, value:CfgValue);
	ArraySize(output:CfgValue, array:CfgValue);
	MakeEnum(output:CfgValue, typeName:String, constructor:Int, arguments:Array<CfgValue>);
	EnumIndex(output:CfgValue, value:CfgValue);
	EnumField(output:CfgValue, value:CfgValue, constructor:Int, field:Int);
}

/** Mandatory transfer of control ending a mutable CFG block. */
enum CfgTerminator {
	Return(value:CfgValue);
	Throw(value:CfgValue);
	Rethrow(value:CfgValue);
	Jump(target:Int);
	Branch(condition:CfgValue, whenTrue:Int, whenFalse:Int);
}

/** Mutable basic block whose terminator is assigned exactly once during construction. */
class CfgBlock {
	public final id:Int;
	public final instructions:Array<Located<CfgInstruction>> = [];
	public var terminator:Null<Located<CfgTerminator>>;

	public function new(id)
		this.id = id;
}

/** Named function input available as a local at CFG entry. */
typedef CfgArgument = {final name:String; final type:IrType;}

/** Complete mutable-local function passed to CFG verification and SSA construction. */
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
