package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;

/** Imperative helper for constructing a single well-formed SSA function. */
class IrBuilder {
	public final blocks:Array<IrBlock> = [];
	public final arguments:Array<IrValue> = [];

	var current:IrBlock;
	var nextValue:Int = 0;

	public function new()
		current = createBlock();

	public function argument(name:String, type:IrType):IrValue {
		var value = new IrValue(nextValue++, name, type);
		arguments.push(value);
		return value;
	}

	public function constInt(value:Int):IrValue {
		var out = temporary(I32);
		emit(ConstInt(out, value));
		return out;
	}

	public function constFloat(value:Float):IrValue {
		var out = temporary(F64);
		emit(ConstFloat(out, value));
		return out;
	}

	public function constString(value:String):IrValue {
		var out = temporary(Bytes);
		emit(ConstString(out, value));
		return out;
	}

	public function phi(type:IrType, inputs:Array<IrPhiInput>):IrValue {
		var out = temporary(type);
		emit(Phi(out, inputs));
		return out;
	}

	public function add(a:IrValue, b:IrValue):IrValue {
		var out = temporary(a.type);
		emit(Add(out, a, b));
		return out;
	}

	public function sub(a:IrValue, b:IrValue):IrValue {
		var out = temporary(a.type);
		emit(Sub(out, a, b));
		return out;
	}

	public function mul(a:IrValue, b:IrValue):IrValue {
		var out = temporary(a.type);
		emit(Mul(out, a, b));
		return out;
	}

	public function div(a:IrValue, b:IrValue):IrValue {
		var out = temporary(a.type);
		emit(Div(out, a, b));
		return out;
	}

	public function mod(a:IrValue, b:IrValue):IrValue {
		var out = temporary(I32);
		emit(Mod(out, a, b));
		return out;
	}

	public function bitAnd(a:IrValue, b:IrValue):IrValue
		return bitwise(a, b, 0);

	public function bitXor(a:IrValue, b:IrValue):IrValue
		return bitwise(a, b, 1);

	public function bitOr(a:IrValue, b:IrValue):IrValue
		return bitwise(a, b, 2);

	public function shiftLeft(a:IrValue, b:IrValue):IrValue
		return shift(a, b, 0);

	public function shiftRight(a:IrValue, b:IrValue):IrValue
		return shift(a, b, 1);

	public function unsignedShiftRight(a:IrValue, b:IrValue):IrValue
		return shift(a, b, 2);

	function bitwise(a:IrValue, b:IrValue, operation:Int):IrValue {
		var out = temporary(I32);
		emit(switch operation {
			case 0: BitAnd(out, a, b);
			case 1: BitXor(out, a, b);
			default: BitOr(out, a, b);
		});
		return out;
	}

	function shift(a:IrValue, b:IrValue, operation:Int):IrValue {
		var out = temporary(I32);
		emit(switch operation {
			case 0: ShiftLeft(out, a, b);
			case 1: ShiftRight(out, a, b);
			default: UnsignedShiftRight(out, a, b);
		});
		return out;
	}

	public function less(a:IrValue, b:IrValue):IrValue
		return compare(a, b, 0);

	public function lessEqual(a:IrValue, b:IrValue):IrValue
		return compare(a, b, 1);

	public function equal(a:IrValue, b:IrValue):IrValue
		return compare(a, b, 2);

	function compare(a:IrValue, b:IrValue, op:Int):IrValue {
		var out = temporary(Bool);
		emit(switch op {
			case 0: Less(out, a, b);
			case 1: LessEqual(out, a, b);
			default: Equal(out, a, b);
		});
		return out;
	}

	public function call(name:String, args:Array<IrValue>, result:IrType):IrValue {
		var out = temporary(result);
		emit(Call(out, name, args));
		return out;
	}

	public function staticClosure(name:String, type:IrType):IrValue {
		var out = temporary(type);
		emit(StaticClosure(out, name));
		return out;
	}

	public function callClosure(closure:IrValue, args:Array<IrValue>, result:IrType):IrValue {
		var out = temporary(result);
		emit(CallClosure(out, closure, args));
		return out;
	}

	public function instanceClosure(name:String, receiver:IrValue, type:IrType):IrValue {
		var out = temporary(type);
		emit(InstanceClosure(out, name, receiver));
		return out;
	}

	public function toVirtual(value:IrValue, type:IrType):IrValue {
		var out = temporary(type);
		emit(ToVirtual(out, value));
		return out;
	}

	public function newObject(typeName:String):IrValue {
		var out = temporary(Obj(typeName));
		emit(NewObject(out, typeName));
		return out;
	}

	public function fieldGet(object:IrValue, fieldName:String, type:IrType):IrValue {
		var out = temporary(type);
		emit(FieldGet(out, object, fieldName));
		return out;
	}

	public function fieldSet(object:IrValue, fieldName:String, value:IrValue):Void
		emit(FieldSet(object, fieldName, value));

	public function createBlock():IrBlock {
		var block = new IrBlock(blocks.length);
		blocks.push(block);
		return block;
	}

	public function select(block:IrBlock):Void
		current = block;

	public function terminate(value:IrTerminator):Void {
		if (current.terminator != null)
			throw 'IR block ${current.id} already has a terminator';
		current.terminator = new Located(value, SourceProvenance.generated("ir-builder"));
	}

	public function isTerminated():Bool
		return current.terminator != null;

	public function currentBlock():IrBlock
		return current;

	public function returnValue(value:IrValue):Void
		terminate(Return(value));

	public function jump(target:IrBlock):Void
		terminate(Jump(target.id));

	public function branch(condition:IrValue, yes:IrBlock, no:IrBlock):Void
		terminate(Branch(condition, yes.id, no.id));

	function emit(instruction:IrInstruction):Void {
		if (isTerminated())
			throw "Cannot emit after terminator";
		current.instructions.push(new Located(instruction, SourceProvenance.generated("ir-builder")));
	}

	function temporary(type:IrType):IrValue
		return new IrValue(nextValue++, 'v$nextValue', type);
}
