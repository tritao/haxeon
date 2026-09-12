package compiler.ir.cfg;

import compiler.ir.cfg.Cfg;
import compiler.ir.Ir.IrType;

/** Enforces the mutable CFG contract before dominance and SSA construction. */
class CfgVerifier {
	public static function verify(fn:CfgFunction):Void {
		if (fn.blocks.length == 0)
			throw 'CFG function ${fn.name} has no entry block';
		if (fn.valueCount < 0)
			throw 'CFG function ${fn.name} has a negative value count';
		var blocks:Map<Int, CfgBlock> = [],
			defined:Array<Int> = [for (_ in 0...fn.valueCount) 0],
			available:Array<Int> = [for (_ in 0...fn.valueCount) 0],
			arguments:Map<String, Bool> = [];
		for (i in 0...fn.blocks.length) {
			var block = fn.blocks[i];
			if (block.id != i || blocks.exists(block.id))
				throw 'Invalid CFG block ${block.id} in ${fn.name}';
			blocks.set(block.id, block);
		}
		for (argument in fn.arguments) {
			if (arguments.exists(argument.name))
				throw 'Duplicate CFG argument "${argument.name}"';
			arguments.set(argument.name, true);
			if (!fn.localTypes.exists(argument.name) || !sameType(fn.localTypes.get(argument.name), argument.type))
				throw 'Wrong CFG type for argument "${argument.name}"';
		}
		for (block in fn.blocks)
			verifyBlock(fn, block, blocks, defined, available);
		var reachable:Map<Int, Bool> = [], work = [0];
		while (work.length > 0) {
			var id = work.pop();
			if (reachable.exists(id))
				continue;
			reachable.set(id, true);
			if (!blocks.exists(id))
				throw 'Unknown CFG block $id in ${fn.name}';
			var block = blocks.get(id), terminator = block.terminator;
			if (terminator == null)
				throw 'Reachable CFG block $id in ${fn.name} has no terminator';
			for (located in block.instructions)
				switch located.value {
					case BeginTry(catchBlock, afterBlock):
						targetBlock(catchBlock, blocks);
						targetBlock(afterBlock, blocks);
						work.push(catchBlock);
					default:
				}
			switch terminator.value {
				case Jump(target):
					work.push(target);
				case Branch(_, yes, no):
					work.push(yes);
					work.push(no);
				case Return(_), Throw(_), Rethrow(_):
			}
		}
	}

	static function verifyBlock(fn:CfgFunction, block:CfgBlock, blocks:Map<Int, CfgBlock>, defined:Array<Int>, available:Array<Int>):Void {
		for (located in block.instructions)
			switch located.value {
				case ConstVoid(out):
					expect(out, Void);
					define(out, defined, available, block.id);
				case ConstInt(out, _):
					switch out.type {
						case I32, I64:
						default: throw 'CFG integer constant ${out.id} must produce I32 or I64';
					}
					define(out, defined, available, block.id);
				case ConstFloat(out, _):
					expect(out, F64);
					define(out, defined, available, block.id);
				case ConstString(out, _):
					expect(out, Bytes);
					define(out, defined, available, block.id);
				case ConstBool(out, _):
					expect(out, Bool);
					define(out, defined, available, block.id);
				case ConstNull(out):
					if (!isReference(out.type))
						throw 'CFG null constant ${out.id} has non-reference type ${out.type} in block ${block.id}';
					define(out, defined, available, block.id);
				case TypeValue(out, _):
					expect(out, TypeRef);
					define(out, defined, available, block.id);
				case ToDyn(out, value):
					require(value, available, block.id);
					expect(out, Dyn);
					define(out, defined, available, block.id);
				case IntToFloat(out, value):
					require(value, available, block.id);
					expect(value, I32);
					expect(out, F64);
					define(out, defined, available, block.id);
				case IntToInt64(out, value):
					require(value, available, block.id);
					expect(value, I32);
					expect(out, I64);
					define(out, defined, available, block.id);
				case FloatToInt(out, value):
					require(value, available, block.id);
					expect(value, F64);
					expect(out, I32);
					define(out, defined, available, block.id);
				case SafeCast(out, value):
					require(value, available, block.id);
					expect(value, Dyn);
					define(out, defined, available, block.id);
				case BeginTry(catchBlock, afterBlock):
					targetBlock(catchBlock, blocks);
					targetBlock(afterBlock, blocks);
				case EndTry(catchBlock):
					targetBlock(catchBlock, blocks);
				case Catch(out):
					expect(out, Dyn);
					define(out, defined, available, block.id);
				case LoadLocal(out, name):
					var type = local(fn, name);
					if (!sameType(out.type, type))
						throw 'Wrong CFG load type for local "$name"';
					define(out, defined, available, block.id);
				case StoreLocal(name, value):
					require(value, available, block.id);
					if (!sameType(value.type, local(fn, name)))
						throw 'Wrong CFG store type for local "$name"';
				case GlobalGet(out, _):
					define(out, defined, available, block.id);
				case GlobalSet(_, value):
					require(value, available, block.id);
				case Add(out, a, b), Sub(out, a, b), Mul(out, a, b), Div(out, a, b):
					require(a, available, block.id);
					require(b, available, block.id);
					if (!sameType(out.type, a.type)
						|| !sameType(a.type, b.type)
						|| (!sameType(a.type, I32) && !sameType(a.type, I64) && !sameType(a.type, F64)))
						throw "CFG arithmetic requires matching numeric values";
					define(out, defined, available, block.id);
				case Mod(out, a, b), BitAnd(out, a, b), BitXor(out, a, b), BitOr(out, a, b), ShiftLeft(out, a, b), ShiftRight(out, a, b),
					UnsignedShiftRight(out, a, b):
					require(a, available, block.id);
					require(b, available, block.id);
					expect(out, I32);
					expect(a, I32);
					expect(b, I32);
					define(out, defined, available, block.id);
				case Less(out, a, b), LessEqual(out, a, b):
					require(a, available, block.id);
					require(b, available, block.id);
					expect(out, Bool);
					if (!sameType(a.type, b.type) || (a.type != I32 && a.type != F64))
						throw "CFG ordered comparison requires matching Int or Float values";
					define(out, defined, available, block.id);
				case Equal(out, a, b):
					require(a, available, block.id);
					require(b, available, block.id);
					expect(out, Bool);
					if (!sameType(a.type, b.type)
						|| (!sameType(a.type, I32) && !sameType(a.type, F64) && !sameType(a.type, Bool) && !isReference(a.type)))
						throw 'CFG equality requires matching primitive or reference values';
					define(out, defined, available, block.id);
				case Call(out, _, arguments), CNativeCall(out, _, arguments):
					for (argument in arguments)
						require(argument, available, block.id);
					define(out, defined, available, block.id);
				case StaticClosure(out, _):
					switch out.type {
						case Function(_, _):
						default: throw 'CFG static closure must produce a function';
					}
					define(out, defined, available, block.id);
				case InstanceClosure(out, _, receiver):
					require(receiver, available, block.id);
					switch out.type {
						case Function(_, _):
						default: throw 'CFG instance closure must produce a function';
					}
					define(out, defined, available, block.id);
				case CallClosure(out, closure, arguments):
					require(closure, available, block.id);
					switch closure.type {
						case Function(argumentTypes, result):
							if (argumentTypes.length != arguments.length || !sameType(out.type, result))
								throw 'CFG closure call has the wrong signature';
							for (i in 0...arguments.length) {
								require(arguments[i], available, block.id);
								if (!sameType(arguments[i].type, argumentTypes[i]))
									throw 'CFG closure call has the wrong argument type';
							}
						default: throw 'CFG closure call requires a function value';
					}
					define(out, defined, available, block.id);
				case ToVirtual(out, value):
					require(value, available, block.id);
					switch out.type {
						case Virtual(_):
						default: throw 'CFG virtual conversion must produce a virtual value';
					}
					define(out, defined, available, block.id);
				case MethodCall(out, object, _, arguments):
					require(object, available, block.id);
					for (argument in arguments)
						require(argument, available, block.id);
					define(out, defined, available, block.id);
				case NewObject(out, _):
					switch out.type {
						case Obj(_):
						default: throw 'CFG object allocation must produce an object';
					}
					define(out, defined, available, block.id);
				case FieldGet(out, object, _):
					require(object, available, block.id);
					define(out, defined, available, block.id);
				case FieldSet(object, _, value):
					require(object, available, block.id);
					require(value, available, block.id);
				case ArrayGet(out, array, index):
					require(array, available, block.id);
					require(index, available, block.id);
					expect(index, I32);
					switch array.type {
						case Array(element):
							if (!sameType(out.type, element)) throw 'CFG array read has the wrong element type';
						default: throw 'CFG array read requires an Array value';
					}
					define(out, defined, available, block.id);
				case ArraySet(array, index, value):
					require(array, available, block.id);
					require(index, available, block.id);
					require(value, available, block.id);
					expect(index, I32);
					switch array.type {
						case Array(element):
							if (!sameType(value.type, element)) throw 'CFG array write value ${value.id} has type ${value.type}, expected $element';
						default: throw 'CFG array write requires an Array value';
					}
				case ArraySize(out, array):
					require(array, available, block.id);
					switch array.type {
						case Array(_):
						default: throw 'CFG array size requires an Array value';
					}
					expect(out, I32);
					define(out, defined, available, block.id);
				case MakeEnum(out, _, _, arguments):
					switch out.type {
						case Enum(_):
						default: throw 'CFG enum construction must produce an enum value';
					}
					for (argument in arguments)
						require(argument, available, block.id);
					define(out, defined, available, block.id);
				case EnumIndex(out, value):
					expect(out, I32);
					switch value.type {
						case Enum(_):
						default: throw 'CFG enum index requires an enum value';
					}
					require(value, available, block.id);
					define(out, defined, available, block.id);
				case EnumField(out, value, _, _):
					switch value.type {
						case Enum(_):
						default: throw 'CFG enum field requires an enum value';
					}
					require(value, available, block.id);
					define(out, defined, available, block.id);
			}
		var terminator = block.terminator;
		if (terminator != null)
			switch terminator.value {
				case Return(value):
					require(value, available, block.id);
					if (!sameType(value.type, fn.result))
						throw 'Wrong CFG return type in ${fn.name}';
				case Throw(value), Rethrow(value):
					require(value, available, block.id);
					expect(value, Dyn);
				case Jump(target):
					if (target == block.id)
						throw 'CFG block ${block.id} in ${fn.name} has a degenerate self-loop';
					targetBlock(target, blocks);
				case Branch(condition, yes, no):
					require(condition, available, block.id);
					expect(condition, Bool);
					targetBlock(yes, blocks);
					targetBlock(no, blocks);
			}
	}

	static function local(fn:CfgFunction, name:String):IrType {
		if (!fn.localTypes.exists(name))
			throw 'Unknown CFG local "$name"';
		return fn.localTypes.get(name);
	}

	static function targetBlock(id:Int, blocks:Map<Int, CfgBlock>):Void
		if (!blocks.exists(id))
			throw 'Unknown CFG block $id';

	static function define(value:CfgValue, global:Array<Int>, available:Array<Int>, blockId:Int):Void {
		var id:Int = value.id;
		if (id < 0 || id >= global.length)
			throw 'CFG value ${value.id} is outside the declared value range';
		if (global[id] != 0)
			throw 'Duplicate CFG value ${value.id}';
		global[id] = 1;
		available[id] = blockId + 1;
	}

	static function require(value:CfgValue, available:Array<Int>, blockId:Int):Void {
		var id:Int = value.id;
		if (id < 0 || id >= available.length || available[id] != blockId + 1)
			throw 'CFG value ${value.id} is used outside its defining block or before definition in block $blockId';
	}

	static function expect(value:CfgValue, type:IrType):Void
		if (!sameType(value.type, type))
			throw 'CFG value ${value.id} has the wrong type';

	static function sameType(left:IrType, right:IrType):Bool
		return switch left {
			case Obj(a): switch right {
					case Obj(b): a == b;
					default: false;
				};
			case Enum(a): switch right {
					case Enum(b): a == b;
					default: false;
				};
			case Abstract(a): switch right {
					case Abstract(b): a == b;
					default: false;
				};
			case Virtual(a): switch right {
					case Virtual(b): a == b;
					default: false;
				};
			case Array(a): switch right {
					case Array(b): sameType(a, b);
					default: false;
				};
			case Function(aArgs, aResult): switch right {
					case Function(bArgs, bResult):
						if (aArgs.length != bArgs.length) false; else {
							var equal = sameType(aResult, bResult);
							for (i in 0...aArgs.length)
								if (!sameType(aArgs[i], bArgs[i]))
									equal = false;
							equal;
						}
					default: false;
				};
			default: left == right;
		};

	static function isReference(type:IrType):Bool
		return switch type {
			case Bytes, Dyn, Obj(_), Enum(_), Abstract(_), Virtual(_), Array(_), Function(_, _): true;
			default: false;
		};
}
