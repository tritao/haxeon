package compiler.ir;

import compiler.ir.Cfg;
import compiler.ir.Ir.IrType;

/** Enforces the mutable CFG contract before dominance and SSA construction. */
class CfgVerifier {
	public static function verify(fn:CfgFunction):Void {
		if (fn.blocks.length == 0)
			throw 'CFG function ${fn.name} has no entry block';
		var blocks:Map<Int, CfgBlock> = [],
			defined:Map<Int, Bool> = [],
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
			var local = fn.localTypes.get(argument.name);
			if (local == null || !sameType(local, argument.type))
				throw 'Wrong CFG type for argument "${argument.name}"';
		}
		for (block in fn.blocks)
			verifyBlock(fn, block, blocks, defined);
		var reachable:Map<Int, Bool> = [], work = [0];
		while (work.length > 0) {
			var id = work.pop();
			if (reachable.exists(id))
				continue;
			reachable.set(id, true);
			var block = blocks.get(id);
			if (block.terminator == null)
				throw 'Reachable CFG block $id in ${fn.name} has no terminator';
			switch block.terminator {
				case Jump(target):
					work.push(target);
				case Branch(_, yes, no):
					work.push(yes);
					work.push(no);
				case Return(_):
			}
		}
	}

	static function verifyBlock(fn:CfgFunction, block:CfgBlock, blocks:Map<Int, CfgBlock>, defined:Map<Int, Bool>):Void {
		var available:Map<Int, Bool> = [];
		for (instruction in block.instructions)
			switch instruction {
				case ConstVoid(out):
					expect(out, Void);
					define(out, defined, available);
				case ConstInt(out, _):
					expect(out, I32);
					define(out, defined, available);
				case ConstFloat(out, _):
					expect(out, F64);
					define(out, defined, available);
				case ConstString(out, _):
					expect(out, Bytes);
					define(out, defined, available);
				case ConstBool(out, _):
					expect(out, Bool);
					define(out, defined, available);
				case ConstNull(out):
					switch out.type {
						case Bytes, Abstract(_), Obj(_), Enum(_), Virtual(_), Array(_), Function(_, _):
						default: throw 'CFG null constant must produce a reference value';
					}
					define(out, defined, available);
				case LoadLocal(out, name):
					var type = local(fn, name);
					if (!sameType(out.type, type))
						throw 'Wrong CFG load type for local "$name"';
					define(out, defined, available);
				case StoreLocal(name, value):
					require(value, available);
					if (!sameType(value.type, local(fn, name)))
						throw 'Wrong CFG store type for local "$name"';
				case Add(out, a, b), Sub(out, a, b), Mul(out, a, b), Div(out, a, b):
					require(a, available);
					require(b, available);
					if (!sameType(out.type, a.type) || !sameType(a.type, b.type) || (!sameType(a.type, I32) && !sameType(a.type, F64)))
						throw "CFG arithmetic requires matching numeric values";
					define(out, defined, available);
				case Mod(out, a, b):
					require(a, available);
					require(b, available);
					expect(out, I32);
					expect(a, I32);
					expect(b, I32);
					define(out, defined, available);
				case Less(out, a, b), LessEqual(out, a, b):
					require(a, available);
					require(b, available);
					expect(out, Bool);
					if (!sameType(a.type, b.type) || (a.type != I32 && a.type != F64))
						throw "CFG ordered comparison requires matching Int or Float values";
					define(out, defined, available);
				case Equal(out, a, b):
					require(a, available);
					require(b, available);
					expect(out, Bool);
					if (!sameType(a.type, b.type)
						|| (!sameType(a.type, I32) && !sameType(a.type, F64) && !sameType(a.type, Bool) && !isReference(a.type)))
						throw 'CFG equality requires matching primitive or reference values';
					define(out, defined, available);
				case Call(out, _, arguments):
					for (argument in arguments)
						require(argument, available);
					define(out, defined, available);
				case StaticClosure(out, _):
					switch out.type {
						case Function(_, _):
						default: throw 'CFG static closure must produce a function';
					}
					define(out, defined, available);
				case InstanceClosure(out, _, receiver):
					require(receiver, available);
					switch out.type {
						case Function(_, _):
						default: throw 'CFG instance closure must produce a function';
					}
					define(out, defined, available);
				case CallClosure(out, closure, arguments):
					require(closure, available);
					switch closure.type {
						case Function(argumentTypes, result):
							if (argumentTypes.length != arguments.length || !sameType(out.type, result))
								throw 'CFG closure call has the wrong signature';
							for (i in 0...arguments.length) {
								require(arguments[i], available);
								if (!sameType(arguments[i].type, argumentTypes[i]))
									throw 'CFG closure call has the wrong argument type';
							}
						default: throw 'CFG closure call requires a function value';
					}
					define(out, defined, available);
				case ToVirtual(out, value):
					require(value, available);
					switch out.type {
						case Virtual(_):
						default: throw 'CFG virtual conversion must produce a virtual value';
					}
					define(out, defined, available);
				case MethodCall(out, object, _, arguments):
					require(object, available);
					for (argument in arguments)
						require(argument, available);
					define(out, defined, available);
				case NewObject(out, _):
					switch out.type {
						case Obj(_):
						default: throw 'CFG object allocation must produce an object';
					}
					define(out, defined, available);
				case FieldGet(out, object, _):
					require(object, available);
					define(out, defined, available);
				case FieldSet(object, _, value):
					require(object, available);
					require(value, available);
				case ArrayGet(out, array, index):
					require(array, available);
					require(index, available);
					expect(index, I32);
					switch array.type {
						case Array(element):
							if (!sameType(out.type, element)) throw 'CFG array read has the wrong element type';
						default: throw 'CFG array read requires an Array value';
					}
					define(out, defined, available);
				case ArraySet(array, index, value):
					require(array, available);
					require(index, available);
					require(value, available);
					expect(index, I32);
					switch array.type {
						case Array(element):
							if (!sameType(value.type, element)) throw 'CFG array write has the wrong element type';
						default: throw 'CFG array write requires an Array value';
					}
				case ArraySize(out, array):
					require(array, available);
					switch array.type {
						case Array(_):
						default: throw 'CFG array size requires an Array value';
					}
					expect(out, I32);
					define(out, defined, available);
				case MakeEnum(out, _, _, arguments):
					switch out.type {
						case Enum(_):
						default: throw 'CFG enum construction must produce an enum value';
					}
					for (argument in arguments)
						require(argument, available);
					define(out, defined, available);
				case EnumIndex(out, value):
					expect(out, I32);
					switch value.type {
						case Enum(_):
						default: throw 'CFG enum index requires an enum value';
					}
					require(value, available);
					define(out, defined, available);
				case EnumField(out, value, _, _):
					switch value.type {
						case Enum(_):
						default: throw 'CFG enum field requires an enum value';
					}
					require(value, available);
					define(out, defined, available);
			}
		if (block.terminator != null)
			switch block.terminator {
				case Return(value):
					require(value, available);
					if (!sameType(value.type, fn.result))
						throw 'Wrong CFG return type in ${fn.name}';
				case Jump(target):
					targetBlock(target, blocks);
				case Branch(condition, yes, no):
					require(condition, available);
					expect(condition, Bool);
					targetBlock(yes, blocks);
					targetBlock(no, blocks);
			}
	}

	static function local(fn:CfgFunction, name:String):IrType {
		var type = fn.localTypes.get(name);
		if (type == null)
			throw 'Unknown CFG local "$name"';
		return type;
	}

	static function targetBlock(id:Int, blocks:Map<Int, CfgBlock>):Void
		if (!blocks.exists(id))
			throw 'Unknown CFG block $id';

	static function define(value:CfgValue, global:Map<Int, Bool>, available:Map<Int, Bool>):Void {
		if (global.exists(value.id))
			throw 'Duplicate CFG value ${value.id}';
		global.set(value.id, true);
		available.set(value.id, true);
	}

	static function require(value:CfgValue, available:Map<Int, Bool>):Void
		if (!available.exists(value.id))
			throw 'CFG value ${value.id} is used outside its defining block or before definition';

	static function expect(value:CfgValue, type:IrType):Void
		if (!sameType(value.type, type))
			throw 'CFG value ${value.id} has the wrong type';

	static function sameType(left:IrType, right:IrType):Bool
		return switch [left, right] {
			case [Obj(a), Obj(b)]: a == b;
			case [Enum(a), Enum(b)]: a == b;
			case [Abstract(a), Abstract(b)]: a == b;
			case [Virtual(a), Virtual(b)]: a == b;
			case [Array(a), Array(b)]: sameType(a, b);
			case [Function(aArgs, aResult), Function(bArgs, bResult)]: aArgs.length == bArgs.length && [
					for (i in 0...aArgs.length)
						sameType(aArgs[i], bArgs[i])
				].indexOf(false) < 0 && sameType(aResult, bResult);
			default: left == right;
		};

	static function isReference(type:IrType):Bool
		return switch type {
			case Bytes, Dyn, Obj(_), Enum(_), Abstract(_), Virtual(_), Array(_), Function(_, _): true;
			default: false;
		};
}
