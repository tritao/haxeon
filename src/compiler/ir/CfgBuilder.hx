package compiler.ir;

import compiler.ir.Cfg;
import compiler.ir.Ir.IrType;

class CfgBuilder {
	public final blocks:Array<CfgBlock> = [];

	var current:CfgBlock;
	var nextValue:Int = 0;

	public function new()
		current = createBlock();

	public function createBlock():CfgBlock {
		var block = new CfgBlock(blocks.length);
		blocks.push(block);
		return block;
	}

	public function select(block:CfgBlock):Void
		current = block;

	public function currentBlock():CfgBlock
		return current;

	public function isTerminated():Bool
		return current.terminator != null;

	public function jump(target:CfgBlock):Void
		terminate(Jump(target.id));

	public function branch(condition:CfgValue, yes:CfgBlock, no:CfgBlock):Void
		terminate(Branch(condition, yes.id, no.id));

	public function returnValue(value:CfgValue):Void
		terminate(Return(value));

	public function load(name:String, type:IrType):CfgValue {
		var out = temporary(type);
		emit(LoadLocal(out, name));
		return out;
	}

	public function store(name:String, value:CfgValue):Void
		emit(StoreLocal(name, value));

	public function constInt(value:Int):CfgValue {
		var out = temporary(I32);
		emit(ConstInt(out, value));
		return out;
	}

	public function constFloat(value:Float):CfgValue {
		var out = temporary(F64);
		emit(ConstFloat(out, value));
		return out;
	}

	public function constString(value:String):CfgValue {
		var out = temporary(Bytes);
		emit(ConstString(out, value));
		return out;
	}

	public function add(a, b):CfgValue
		return binary(a, b, 0);

	public function sub(a, b):CfgValue
		return binary(a, b, 1);

	public function mul(a, b):CfgValue
		return binary(a, b, 2);

	public function div(a, b):CfgValue
		return binary(a, b, 3);

	public function less(a, b):CfgValue
		return binary(a, b, 4, Bool);

	public function lessEqual(a, b):CfgValue
		return binary(a, b, 5, Bool);

	public function equal(a, b):CfgValue
		return binary(a, b, 6, Bool);

	public function call(name:String, args:Array<CfgValue>, result:IrType):CfgValue {
		var out = temporary(result);
		emit(Call(out, name, args));
		return out;
	}

	function binary(a:CfgValue, b:CfgValue, kind:Int, ?type:IrType):CfgValue {
		var out = temporary(type == null ? a.type : type);
		emit(switch kind {
			case 0: Add(out, a, b);
			case 1: Sub(out, a, b);
			case 2: Mul(out, a, b);
			case 3: Div(out, a, b);
			case 4: Less(out, a, b);
			case 5: LessEqual(out, a, b);
			default: Equal(out, a, b);
		});
		return out;
	}

	function temporary(type):CfgValue
		return new CfgValue(nextValue++, type);

	function emit(value):Void {
		if (isTerminated())
			throw "Cannot emit after CFG terminator";
		current.instructions.push(value);
	}

	function terminate(value):Void {
		if (isTerminated())
			throw 'CFG block ${current.id} already has a terminator';
		current.terminator = value;
	}
}
