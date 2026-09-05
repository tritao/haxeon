package compiler.ir;

import compiler.ir.Cfg;
import compiler.ir.Ir.IrType;

class CfgBuilder {
	public final blocks:Array<CfgBlock> = [];

	var current:CfgBlock;
	var nextValue:Int = 0;
	var activeTraps:Int = 0;
	var localAliases:Map<String, Array<String>> = [];

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

	/** Attach a forward edge after both branch bodies have been lowered. */
	public function jumpFrom(source:CfgBlock, target:CfgBlock):Void {
		if (source.terminator != null)
			throw 'CFG block ${source.id} already has a terminator';
		source.terminator = Jump(target.id);
	}

	public function branch(condition:CfgValue, yes:CfgBlock, no:CfgBlock):Void
		terminate(Branch(condition, yes.id, no.id));

	public function returnValue(value:CfgValue):Void
		terminate(Return(value));

	public function returnVoid():Void {
		var out = temporary(Void);
		emit(ConstVoid(out));
		terminate(Return(out));
	}

	public function throwValue(value:CfgValue):Void
		terminate(Throw(value));

	public function rethrowValue(value:CfgValue):Void
		terminate(Rethrow(value));

	/** Seal a block that is unreachable from the function entry. */
	public function markUnreachable():Void
		if (!isTerminated())
			current.terminator = Jump(current.id);

	public function beginTry(catchBlock:CfgBlock, afterBlock:CfgBlock):Void {
		emit(BeginTry(catchBlock.id, afterBlock.id));
		activeTraps++;
	}

	public function endTry():Void {
		if (activeTraps == 0)
			throw "No active try block";
		emit(EndTry);
		activeTraps--;
	}

	/** Forget a trap after all paths in the current block have terminated. */
	public function discardTry():Void {
		if (activeTraps == 0)
			throw "No active try block";
		activeTraps--;
	}

	/** Close traps on a terminating path without changing the lexical stack. */
	public function closeTrapsForExit():Void
		closeTrapsToDepth(0);

	public function trapDepth():Int
		return activeTraps;

	/** Close traps opened inside a destination scope without mutating lexical state. */
	public function closeTrapsToDepth(depth:Int):Void {
		if (depth < 0 || depth > activeTraps)
			throw 'Invalid trap depth $depth';
		for (_ in depth...activeTraps)
			emit(EndTry);
	}

	public function catchValue():CfgValue {
		var out = temporary(Dyn);
		emit(Catch(out));
		return out;
	}

	public function safeCast(value:CfgValue, type:IrType):CfgValue {
		var out = temporary(type);
		emit(SafeCast(out, value));
		return out;
	}

	public function typeValue(type:IrType):CfgValue {
		var out = temporary(TypeRef);
		emit(TypeValue(out, type));
		return out;
	}

	public function pushLocalAlias(name:String, internalName:String):Void {
		var aliases = localAliases.get(name);
		if (aliases == null) {
			aliases = [];
			localAliases.set(name, aliases);
		}
		aliases.push(internalName);
	}

	public function popLocalAlias(name:String):Void {
		var aliases = localAliases.get(name);
		if (aliases == null || aliases.length == 0)
			throw 'No active CFG local alias for "$name"';
		aliases.pop();
	}

	public function load(name:String, type:IrType):CfgValue {
		var out = temporary(type);
		emit(LoadLocal(out, resolveLocal(name)));
		return out;
	}

	public function store(name:String, value:CfgValue):Void
		emit(StoreLocal(resolveLocal(name), value));

	function resolveLocal(name:String):String {
		var aliases = localAliases.get(name);
		return aliases == null || aliases.length == 0 ? name : aliases[aliases.length - 1];
	}

	public function globalGet(name:String, type:IrType):CfgValue {
		var out = temporary(type);
		emit(GlobalGet(out, name));
		return out;
	}

	public function globalSet(name:String, value:CfgValue):Void
		emit(GlobalSet(name, value));

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

	public function constBool(value:Bool):CfgValue {
		var out = temporary(Bool);
		emit(ConstBool(out, value));
		return out;
	}

	public function constNull(type:IrType):CfgValue {
		var out = temporary(type);
		emit(ConstNull(out));
		return out;
	}

	public function toDyn(value:CfgValue):CfgValue {
		if (value.type == Dyn)
			return value;
		var out = temporary(Dyn);
		emit(ToDyn(out, value));
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

	public function mod(a, b):CfgValue
		return binary(a, b, 7);

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

	public function staticClosure(name:String, type:IrType):CfgValue {
		var out = temporary(type);
		emit(StaticClosure(out, name));
		return out;
	}

	public function callClosure(closure:CfgValue, args:Array<CfgValue>, result:IrType):CfgValue {
		var out = temporary(result);
		emit(CallClosure(out, closure, args));
		return out;
	}

	public function toVirtual(value:CfgValue, type:IrType):CfgValue {
		var out = temporary(type);
		emit(ToVirtual(out, value));
		return out;
	}

	public function methodCall(object:CfgValue, methodName:String, args:Array<CfgValue>, result:IrType):CfgValue {
		var out = temporary(result);
		emit(MethodCall(out, object, methodName, args));
		return out;
	}

	public function instanceClosure(name:String, receiver:CfgValue, type:IrType):CfgValue {
		var out = temporary(type);
		emit(InstanceClosure(out, name, receiver));
		return out;
	}

	public function newObject(typeName:String):CfgValue {
		var out = temporary(Obj(typeName));
		emit(NewObject(out, typeName));
		return out;
	}

	public function fieldGet(object:CfgValue, fieldName:String, type:IrType):CfgValue {
		var out = temporary(type);
		emit(FieldGet(out, object, fieldName));
		return out;
	}

	public function fieldSet(object:CfgValue, fieldName:String, value:CfgValue):Void
		emit(FieldSet(object, fieldName, value));

	public function arrayGet(array:CfgValue, index:CfgValue, type:IrType):CfgValue {
		var out = temporary(type);
		emit(ArrayGet(out, array, index));
		return out;
	}

	public function arraySet(array:CfgValue, index:CfgValue, value:CfgValue):Void
		emit(ArraySet(array, index, value));

	public function arraySize(array:CfgValue):CfgValue {
		var out = temporary(I32);
		emit(ArraySize(out, array));
		return out;
	}

	public function makeEnum(typeName:String, constructor:Int, arguments:Array<CfgValue>):CfgValue {
		var out = temporary(Enum(typeName));
		emit(MakeEnum(out, typeName, constructor, arguments));
		return out;
	}

	public function enumIndex(value:CfgValue):CfgValue {
		var out = temporary(I32);
		emit(EnumIndex(out, value));
		return out;
	}

	public function enumField(value:CfgValue, constructor:Int, field:Int, type:IrType):CfgValue {
		var out = temporary(type);
		emit(EnumField(out, value, constructor, field));
		return out;
	}

	function binary(a:CfgValue, b:CfgValue, kind:Int, ?type:IrType):CfgValue {
		var out = temporary(type == null ? a.type : type);
		emit(switch kind {
			case 0: Add(out, a, b);
			case 1: Sub(out, a, b);
			case 2: Mul(out, a, b);
			case 3: Div(out, a, b);
			case 7: Mod(out, a, b);
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
