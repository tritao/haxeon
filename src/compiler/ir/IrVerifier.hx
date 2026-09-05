package compiler.ir;

import compiler.ir.Ir;

class IrVerifier {
	public static function verify(program:IrProgram):Void {
		var signatures:Map<String, {arguments:Array<IrType>, result:IrType}> = [];
		for (native in program.natives)
			addSignature(signatures, native.name, native.arguments, native.result);
		for (fn in program.functions)
			addSignature(signatures, fn.name, [for (a in fn.arguments) a.type], fn.result);
		var objects:Map<String, IrObject> = [];
		for (object in program.objects) {
			if (objects.exists(object.name))
				throw 'Duplicate IR object "${object.name}"';
			objects.set(object.name, object);
		}
		if (!signatures.exists(program.entryPoint))
			throw 'Unknown IR entry point "${program.entryPoint}"';
		for (fn in program.functions)
			verifyFunction(fn, signatures, objects);
	}

	static function verifyFunction(fn:IrFunction, signatures:Map<String, {arguments:Array<IrType>, result:IrType}>, objects:Map<String, IrObject>):Void {
		if (fn.blocks.length == 0)
			throw 'IR function ${fn.name} has no entry block';
		var blocks:Map<Int, IrBlock> = [], values:Map<Int, IrType> = [];
		for (block in fn.blocks) {
			if (blocks.exists(block.id))
				throw 'Duplicate IR block ${block.id}';
			blocks.set(block.id, block);
		}
		for (argument in fn.arguments)
			define(values, argument);
		var reachable:Map<Int, Bool> = [], work = [fn.blocks[0].id];
		while (work.length > 0) {
			var id = work.pop();
			if (reachable.exists(id))
				continue;
			var block = blocks.get(id);
			if (block == null)
				throw 'Unknown IR block $id in ${fn.name}';
			reachable.set(id, true);
			for (instruction in block.instructions)
				switch instruction {
					case Phi(out, _):
						define(values, out);
					default:
				}
			for (instruction in block.instructions)
				verifyInstruction(instruction, values, signatures, objects);
			if (block.terminator == null)
				throw 'Reachable IR block $id in ${fn.name} has no terminator';
			switch block.terminator {
				case Return(value):
					require(values, value);
					if (!sameType(value.type, fn.result))
						throw 'Wrong return type in ${fn.name}';
				case Jump(target):
					work.push(target);
				case Branch(condition, yes, no):
					require(values, condition);
					if (!sameType(condition.type, Bool))
						throw 'IR branch condition is not Bool';
					work.push(yes);
					work.push(no);
			}
		}
		var predecessors:Map<Int, Map<Int, Bool>> = [];
		for (block in fn.blocks)
			if (reachable.exists(block.id) && block.terminator != null)
				switch block.terminator {
					case Jump(target):
						addPredecessor(predecessors, target, block.id);
					case Branch(_, yes, no):
						addPredecessor(predecessors, yes, block.id);
						addPredecessor(predecessors, no, block.id);
					default:
				}
		for (block in fn.blocks)
			if (reachable.exists(block.id))
				for (instruction in block.instructions)
					switch instruction {
						case Phi(out, inputs):
							var expected = predecessors.get(block.id),
								seen:Map<Int, Bool> = [];
							if (expected == null || inputs.length != countKeys(expected))
								throw 'Phi ${out.id} does not cover every predecessor';
							for (input in inputs) {
								if (!expected.exists(input.block) || seen.exists(input.block))
									throw 'Invalid phi predecessor ${input.block}';
								seen.set(input.block, true);
								require(values, input.value);
								if (!sameType(input.value.type, out.type))
									throw 'Wrong phi input type for ${out.id}';
							}
						default:
					}
	}

	static function verifyInstruction(instruction:IrInstruction, values:Map<Int, IrType>, signatures, objects:Map<String, IrObject>):Void
		switch instruction {
			case Phi(_, _):
			case ConstVoid(out):
				expect(out, Void);
				define(values, out);
			case ConstInt(out, _):
				expect(out, I32);
				define(values, out);
			case ConstFloat(out, _):
				expect(out, F64);
				define(values, out);
			case ConstString(out, _):
				expect(out, Bytes);
				define(values, out);
			case Add(out, a, b), Sub(out, a, b), Mul(out, a, b), Div(out, a, b):
				if (!sameType(out.type, a.type) || !sameType(a.type, b.type) || (!sameType(a.type, I32) && !sameType(a.type, F64)))
					throw "IR arithmetic requires matching numeric values";
				require(values, a);
				require(values, b);
				define(values, out);
			case Less(out, a, b), LessEqual(out, a, b), Equal(out, a, b):
				expect(out, Bool);
				expect(a, I32);
				expect(b, I32);
				require(values, a);
				require(values, b);
				define(values, out);
			case Call(out, name, args):
				var signature = signatures.get(name);
				if (signature == null)
					throw 'Unknown IR call "$name"';
				if (args.length != signature.arguments.length)
					throw 'Wrong IR argument count for "$name"';
				for (i in 0...args.length) {
					require(values, args[i]);
					if (!compatibleType(args[i].type, signature.arguments[i], objects))
						throw 'Wrong IR argument type for "$name"';
				}
				if (!sameType(out.type, signature.result))
					throw 'Wrong IR result type for "$name"';
				define(values, out);
			case StaticClosure(out, name):
				var signature = signatures.get(name);
				if (signature == null)
					throw 'Unknown IR closure target "$name"';
				if (!sameType(out.type, Function(signature.arguments, signature.result)))
					throw 'Wrong IR closure type for "$name"';
				define(values, out);
			case InstanceClosure(out, name, receiver):
				var signature = signatures.get(name);
				if (signature == null || signature.arguments.length == 0)
					throw 'Unknown or receiver-less IR closure target "$name"';
				require(values, receiver);
				if (!compatibleType(receiver.type, signature.arguments[0], objects))
					throw 'Wrong IR instance closure receiver type';
				var closureType = Function(signature.arguments.slice(1), signature.result);
				if (!sameType(out.type, closureType))
					throw 'Wrong IR instance closure type for "$name"';
				define(values, out);
			case CallClosure(out, closure, args):
				require(values, closure);
				var functionType = switch closure.type {
					case Function(arguments, result): {arguments: arguments, result: result};
					default: throw 'IR closure value ${closure.id} is not callable';
				};
				if (args.length != functionType.arguments.length)
					throw 'Wrong IR closure argument count';
				for (i in 0...args.length) {
					require(values, args[i]);
					if (!sameType(args[i].type, functionType.arguments[i]))
						throw 'Wrong IR closure argument type';
				}
				if (!sameType(out.type, functionType.result))
					throw 'Wrong IR closure result type';
				define(values, out);
			case MethodCall(out, object, methodName, args):
				var objectType = requireObject(object, values, objects),
					functionName = findMethodFunction(objectType, methodName, objects),
					signature = functionName == null ? null : signatures.get(functionName);
				if (signature == null || signature.arguments.length != args.length + 1)
					throw 'Unknown or mismatched IR method "$methodName"';
				if (!compatibleType(object.type, signature.arguments[0], objects))
					throw 'Wrong IR method receiver type';
				for (i in 0...args.length) {
					require(values, args[i]);
					if (!compatibleType(args[i].type, signature.arguments[i + 1], objects))
						throw 'Wrong IR method argument type';
				}
				if (!sameType(out.type, signature.result))
					throw 'Wrong IR method result type';
				define(values, out);
			case NewObject(out, typeName):
				if (!objects.exists(typeName) || !isObjectType(out.type, typeName))
					throw 'Unknown or mismatched IR object "$typeName"';
				define(values, out);
			case FieldGet(out, object, fieldName):
				var objectType = requireObject(object, values, objects),
					field = findField(objectType, fieldName, objects);
				if (field == null || !sameType(out.type, field.type))
					throw 'Unknown or mismatched IR field "${objectType.name}.$fieldName"';
				define(values, out);
			case FieldSet(object, fieldName, value):
				var objectType = requireObject(object, values, objects),
					field = findField(objectType, fieldName, objects);
				if (field == null || !sameType(field.type, value.type))
					throw 'Unknown or mismatched IR field "${objectType.name}.$fieldName"';
				require(values, value);
			case ArrayGet(out, array, index):
				require(values, array);
				require(values, index);
				expect(index, I32);
				switch array.type {
					case Array(element):
						if (!sameType(out.type, element)) throw 'IR array read has the wrong element type';
					default: throw 'IR array read requires an Array value';
				}
				define(values, out);
			case ArraySet(array, index, value):
				require(values, array);
				require(values, index);
				require(values, value);
				expect(index, I32);
				switch array.type {
					case Array(element):
						if (!sameType(value.type, element)) throw 'IR array write has the wrong element type';
					default: throw 'IR array write requires an Array value';
				}
			case ArraySize(out, array):
				require(values, array);
				switch array.type {
					case Array(_):
					default: throw 'IR array size requires an Array value';
				}
				expect(out, I32);
				define(values, out);
		}

	static function requireObject(value:IrValue, values:Map<Int, IrType>, objects:Map<String, IrObject>):IrObject {
		require(values, value);
		return switch value.type {
			case Obj(name):
				var object = objects.get(name);
				if (object == null)
					throw 'Unknown IR object "$name"';
				object;
			default: throw 'IR value ${value.id} is not an object';
		};
	}

	static function isObjectType(type:IrType, name:String):Bool
		return switch type {
			case Obj(value): value == name;
			default: false;
		};

	static function findField(object:IrObject, name:String, objects:Map<String, IrObject>):Null<IrObjectField> {
		for (field in object.fields)
			if (field.name == name)
				return field;
		if (object.base != null) {
			var base = objects.get(object.base);
			if (base != null)
				return findField(base, name, objects);
		}
		return null;
	}

	static function findMethodFunction(object:IrObject, name:String, objects:Map<String, IrObject>):Null<String> {
		for (method in object.methods)
			if (method.name == name)
				return method.functionName;
		return object.base == null ? null : findMethodFunction(objects.get(object.base), name, objects);
	}

	static function addPredecessor(map:Map<Int, Map<Int, Bool>>, target:Int, source:Int):Void {
		var found = map.get(target);
		if (found == null) {
			found = [];
			map.set(target, found);
		}
		found.set(source, true);
	}

	static function countKeys(map:Map<Int, Bool>):Int {
		var count = 0;
		for (_ in map.keys())
			count++;
		return count;
	}

	static function addSignature(map, name, arguments, result):Void {
		if (map.exists(name))
			throw 'Duplicate IR function "$name"';
		map.set(name, {arguments: arguments, result: result});
	}

	static function define(values:Map<Int, IrType>, value:IrValue):Void {
		if (values.exists(value.id))
			throw 'Duplicate IR value ${value.id}';
		values.set(value.id, value.type);
	}

	static function require(values:Map<Int, IrType>, value:IrValue):Void {
		if (!values.exists(value.id))
			throw 'IR value ${value.id} is used before definition';
	}

	static function expect(value:IrValue, type:IrType):Void {
		if (!sameType(value.type, type))
			throw 'IR value ${value.id} has the wrong type';
	}

	static function sameType(left:IrType, right:IrType):Bool
		return switch [left, right] {
			case [Obj(a), Obj(b)]: a == b;
			case [Array(a), Array(b)]: sameType(a, b);
			case [Function(aArgs, aResult), Function(bArgs, bResult)]: aArgs.length == bArgs.length && [
					for (i in 0...aArgs.length)
						sameType(aArgs[i], bArgs[i])
				].indexOf(false) < 0 && sameType(aResult, bResult);
			default: left == right;
		};

	static function compatibleType(actual:IrType, expected:IrType, objects:Map<String, IrObject>):Bool {
		if (sameType(actual, expected))
			return true;
		return switch [actual, expected] {
			case [Obj(actualName), Obj(expectedName)]: var object = objects.get(actualName); object != null && object.base != null && compatibleType(Obj(object.base),
					expected, objects);
			case [Array(actualElement), Array(expectedElement)]: sameType(actualElement, expectedElement);
			default: false;
		};
	}
}
