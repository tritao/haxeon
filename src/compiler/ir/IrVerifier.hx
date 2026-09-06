package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.Ir.IrInterface;
import compiler.ir.Ir.IrEnum;

/** Rejects malformed or ill-typed SSA programs before backend lowering. */
class IrVerifier {
	public static function verify(program:IrProgram):Void {
		var signatures:Map<String, {arguments:Array<IrType>, result:IrType}> = [];
		for (native in program.natives)
			addSignature(signatures, native.name, native.arguments, native.result);
		for (fn in program.functions)
			addSignature(signatures, fn.name, [for (a in fn.arguments) a.type], fn.result);
		var objects:Map<String, IrObject> = [];
		var interfaces:Map<String, IrInterface> = [];
		var enums:Map<String, IrEnum> = [];
		for (object in program.objects) {
			if (objects.exists(object.name))
				throw 'Duplicate IR object "${object.name}"';
			objects.set(object.name, object);
		}
		for (interfaceDecl in program.interfaces) {
			if (interfaces.exists(interfaceDecl.name))
				throw 'Duplicate IR interface "${interfaceDecl.name}"';
			interfaces.set(interfaceDecl.name, interfaceDecl);
		}
		for (enumDecl in program.enums) {
			if (enums.exists(enumDecl.name))
				throw 'Duplicate IR enum "${enumDecl.name}"';
			enums.set(enumDecl.name, enumDecl);
		}
		var globals:Map<String, IrType> = [];
		for (field in program.staticFields) {
			if (globals.exists(field.name))
				throw 'Duplicate IR static field "${field.name}"';
			globals.set(field.name, field.type);
		}
		if (!signatures.exists(program.entryPoint))
			throw 'Unknown IR entry point "${program.entryPoint}"';
		for (fn in program.functions)
			try {
				verifyFunction(fn, signatures, objects, interfaces, enums, globals);
			} catch (error:String) {
				throw 'IR verification failed for ${fn.name}: $error';
			}
	}

	static function verifyFunction(fn:IrFunction, signatures:Map<String, {arguments:Array<IrType>, result:IrType}>, objects:Map<String, IrObject>,
			interfaces:Map<String, IrInterface>, enums:Map<String, IrEnum>, globals:Map<String, IrType>):Void {
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
			if (!blocks.exists(id))
				throw 'Unknown IR block $id in ${fn.name}';
			var block = blocks.get(id);
			reachable.set(id, true);
			for (instruction in block.instructions)
				switch instruction {
					case BeginTry(catchBlock, afterBlock):
						if (!blocks.exists(catchBlock))
							throw 'Unknown IR block $catchBlock in ${fn.name}';
						if (!blocks.exists(afterBlock))
							throw 'Unknown IR block $afterBlock in ${fn.name}';
						work.push(catchBlock);
					default:
				}
			for (instruction in block.instructions)
				switch instruction {
					case Phi(out, _):
						define(values, out);
					default:
				}
			for (instruction in block.instructions)
				verifyInstruction(instruction, values, signatures, objects, interfaces, enums, globals);
			var terminator = block.terminator;
			if (terminator == null)
				throw 'Reachable IR block $id in ${fn.name} has no terminator';
			switch terminator {
				case Return(value):
					require(values, value);
					if (!sameType(value.type, fn.result))
						throw 'Wrong return type in ${fn.name}';
				case Throw(value):
					require(values, value);
					if (value.type != Dyn)
						throw 'IR throw value is not Dyn';
				case Rethrow(value):
					require(values, value);
					if (value.type != Dyn)
						throw 'IR rethrow value is not Dyn';
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
		for (block in fn.blocks) {
			var terminator = block.terminator;
			if (reachable.exists(block.id) && terminator != null)
				switch terminator {
					case Jump(target):
						addPredecessor(predecessors, target, block.id);
					case Branch(_, yes, no):
						addPredecessor(predecessors, yes, block.id);
						addPredecessor(predecessors, no, block.id);
					default:
				}
		}
		for (block in fn.blocks)
			if (reachable.exists(block.id))
				for (instruction in block.instructions)
					switch instruction {
						case Phi(out, inputs):
							if (!predecessors.exists(block.id))
								throw 'Phi ${out.id} does not cover every predecessor';
							var expected = predecessors.get(block.id),
								seen:Map<Int, Bool> = [];
							if (inputs.length != countKeys(expected))
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

	static function verifyInstruction(instruction:IrInstruction, values:Map<Int, IrType>, signatures, objects:Map<String, IrObject>,
			interfaces:Map<String, IrInterface>, enums:Map<String, IrEnum>, globals:Map<String, IrType>):Void
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
			case ConstBool(out, _):
				expect(out, Bool);
				define(values, out);
			case ConstNull(out):
				if (!isReference(out.type))
					throw 'IR null constant must produce a reference value';
				define(values, out);
			case TypeValue(out, _):
				expect(out, TypeRef);
				define(values, out);
			case ToDyn(out, value):
				require(values, value);
				if (out.type != Dyn)
					throw 'IR dynamic conversion must produce Dyn';
				define(values, out);
			case SafeCast(out, value):
				require(values, value);
				if (value.type != Dyn)
					throw 'IR safe cast source must be Dyn';
				define(values, out);
			case BeginTry(catchBlock, afterBlock):
			case EndTry:
			case Catch(out):
				if (out.type != Dyn)
					throw 'IR catch value must be Dyn';
				define(values, out);
			case GlobalGet(out, name):
				if (!globals.exists(name))
					throw 'Unknown IR static field "$name"';
				var type = globals.get(name);
				if (!sameType(out.type, type))
					throw 'Mismatched IR static field "$name" (declared=${Std.string(type)}, actual=${Std.string(out.type)})';
				define(values, out);
			case GlobalSet(name, value):
				if (!globals.exists(name))
					throw 'Unknown IR static field "$name"';
				var type = globals.get(name);
				if (!sameType(value.type, type))
					throw 'Mismatched IR static field "$name" (declared=${Std.string(type)}, actual=${Std.string(value.type)})';
				require(values, value);
			case Add(out, a, b), Sub(out, a, b), Mul(out, a, b), Div(out, a, b):
				if (!sameType(out.type, a.type) || !sameType(a.type, b.type) || (!sameType(a.type, I32) && !sameType(a.type, F64)))
					throw "IR arithmetic requires matching numeric values";
				require(values, a);
				require(values, b);
				define(values, out);
			case Mod(out, a, b), BitAnd(out, a, b), BitXor(out, a, b), BitOr(out, a, b), ShiftLeft(out, a, b), ShiftRight(out, a, b),
				UnsignedShiftRight(out, a, b):
				expect(out, I32);
				expect(a, I32);
				expect(b, I32);
				require(values, a);
				require(values, b);
				define(values, out);
			case Less(out, a, b), LessEqual(out, a, b):
				expect(out, Bool);
				if (!sameType(a.type, b.type) || (a.type != I32 && a.type != F64))
					throw 'IR ordered comparison requires matching Int or Float values';
				require(values, a);
				require(values, b);
				define(values, out);
			case Equal(out, a, b):
				expect(out, Bool);
				require(values, a);
				require(values, b);
				if (!sameType(a.type, b.type)
					|| (!sameType(a.type, I32) && !sameType(a.type, F64) && !sameType(a.type, Bool) && !isReference(a.type)))
					throw 'IR equality requires matching primitive or reference values';
				define(values, out);
			case Call(out, name, args):
				if (!signatures.exists(name))
					throw 'Unknown IR call "$name"';
				var signature = signatures.get(name);
				if (args.length != signature.arguments.length)
					throw 'Wrong IR argument count for "$name"';
				for (i in 0...args.length) {
					require(values, args[i]);
					if (!compatibleType(args[i].type, signature.arguments[i], objects, interfaces))
						throw 'Wrong IR argument type for "$name"';
				}
				if (!sameType(out.type, signature.result) && !abiCompatible(out.type, signature.result))
					throw 'Wrong IR result type for "$name"';
				define(values, out);
			case StaticClosure(out, name):
				if (!signatures.exists(name))
					throw 'Unknown IR closure target "$name"';
				var signature = signatures.get(name);
				if (!sameType(out.type, Function(signature.arguments, signature.result)))
					throw 'Wrong IR closure type for "$name"';
				define(values, out);
			case InstanceClosure(out, name, receiver):
				if (!signatures.exists(name))
					throw 'Unknown or receiver-less IR closure target "$name"';
				var signature = signatures.get(name);
				if (signature.arguments.length == 0)
					throw 'Unknown or receiver-less IR closure target "$name"';
				require(values, receiver);
				if (!compatibleType(receiver.type, signature.arguments[0], objects, interfaces))
					throw 'Wrong IR instance closure receiver type';
				var closureType:IrType = Function(signature.arguments.slice(1), signature.result);
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
			case ToVirtual(out, value):
				require(values, value);
				switch out.type {
					case Virtual(_):
					default: throw 'IR virtual conversion must produce a virtual value';
				}
				define(values, out);
			case MethodCall(out, object, methodName, args):
				var signature = methodSignature(object.type, methodName, signatures, objects, interfaces);
				if (signature == null || signature.arguments.length != args.length + 1)
					throw 'Unknown or mismatched IR method "$methodName"';
				if (!compatibleType(object.type, signature.arguments[0], objects, interfaces))
					throw 'Wrong IR method receiver type';
				for (i in 0...args.length) {
					require(values, args[i]);
					if (!compatibleType(args[i].type, signature.arguments[i + 1], objects, interfaces))
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
			case MakeEnum(out, typeName, constructor, arguments):
				if (!isEnumType(out.type, typeName, enums))
					throw 'Unknown or mismatched IR enum "$typeName"';
				if (!enums.exists(typeName))
					throw 'Invalid IR enum constructor "$typeName"';
				var enumDecl = enums.get(typeName);
				if (constructor < 0 || constructor >= enumDecl.cases.length)
					throw 'Invalid IR enum constructor "$typeName"';
				var constructorDecl = enumDecl.cases[constructor];
				if (constructorDecl.params.length != arguments.length)
					throw 'Invalid IR enum constructor "$typeName"';
				for (i in 0...arguments.length) {
					require(values, arguments[i]);
					if (!sameType(arguments[i].type, constructorDecl.params[i]))
						throw 'Wrong IR enum payload type for "$typeName"';
				}
				define(values, out);
			case EnumIndex(out, value):
				expect(out, I32);
				require(values, value);
				switch value.type {
					case Enum(_):
					default: throw 'IR enum index requires an enum value';
				}
				define(values, out);
			case EnumField(out, value, constructor, field):
				require(values, value);
				var typeName = switch value.type {
					case Enum(name): name;
					default: throw 'IR enum field requires an enum value';
				};
				if (!enums.exists(typeName))
					throw 'Invalid IR enum field constructor';
				var enumDecl = enums.get(typeName);
				if (constructor < 0 || constructor >= enumDecl.cases.length)
					throw 'Invalid IR enum field constructor';
				var constructorDecl = enumDecl.cases[constructor];
				if (field < 0 || field >= constructorDecl.params.length || !sameType(out.type, constructorDecl.params[field]))
					throw 'Invalid IR enum field';
				define(values, out);
		}

	static function requireObject(value:IrValue, values:Map<Int, IrType>, objects:Map<String, IrObject>):IrObject {
		require(values, value);
		return switch value.type {
			case Obj(name):
				if (!objects.exists(name))
					throw 'Unknown IR object "$name"';
				objects.get(name);
			default: throw 'IR value ${value.id} is not an object';
		};
	}

	static function isObjectType(type:IrType, name:String):Bool
		return switch type {
			case Obj(value): value == name;
			default: false;
		};

	static function isEnumType(type:IrType, name:String, enums:Map<String, IrEnum>):Bool
		return switch type {
			case Enum(value): value == name && enums.exists(name);
			default: false;
		};

	static function findField(object:IrObject, name:String, objects:Map<String, IrObject>):Null<IrObjectField> {
		for (field in object.fields)
			if (field.name == name)
				return field;
		var baseName = object.base;
		if (baseName != null && objects.exists(baseName)) {
			var base = objects.get(baseName);
			return findField(base, name, objects);
		}
		return null;
	}

	static function findMethodFunction(object:IrObject, name:String, objects:Map<String, IrObject>):Null<String> {
		for (method in object.methods)
			if (method.name == name)
				return method.functionName;
		var baseName = object.base;
		if (baseName == null || !objects.exists(baseName))
			return null;
		return findMethodFunction(objects.get(baseName), name, objects);
	}

	static function methodSignature(type:IrType, name:String, signatures, objects:Map<String, IrObject>,
			interfaces:Map<String, IrInterface>):Null<{arguments:Array<IrType>, result:IrType}> {
		return switch type {
			case Obj(_):
				var object = requireObjectType(type, objects),
					functionName = findMethodFunction(object, name, objects);
				if (functionName == null || !signatures.exists(functionName)) null; else signatures.get(functionName);
			case Virtual(interfaceName):
				if (!interfaces.exists(interfaceName)) null; else {
					var interfaceDecl = interfaces.get(interfaceName);
					var method = findInterfaceMethod(interfaceDecl, name, interfaces);
					if (method == null)
						null;
					else {
						var arguments:Array<IrType> = [Virtual(interfaceName)];
						arguments = arguments.concat(method.arguments);
						{arguments: arguments, result: method.result};
					}
				}
			default: null;
		};
	}

	static function findInterfaceMethod(interfaceDecl:IrInterface, name:String, interfaces:Map<String, IrInterface>):Null<IrInterfaceMethod> {
		for (method in interfaceDecl.methods)
			if (method.name == name)
				return method;
		for (base in interfaceDecl.bases) {
			if (interfaces.exists(base)) {
				var baseDecl = interfaces.get(base);
				var found = findInterfaceMethod(baseDecl, name, interfaces);
				if (found != null)
					return found;
			}
		}
		return null;
	}

	static function requireObjectType(type:IrType, objects:Map<String, IrObject>):IrObject {
		return switch type {
			case Obj(name):
				if (!objects.exists(name))
					throw 'Unknown IR object "$name"';
				objects.get(name);
			default: throw "IR method receiver is not an object";
		};
	}

	static function addPredecessor(map:Map<Int, Map<Int, Bool>>, target:Int, source:Int):Void {
		var found:Map<Int, Bool>;
		if (map.exists(target))
			found = map.get(target);
		else {
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

	static function addSignature(map:Map<String, {arguments:Array<IrType>, result:IrType}>, name:String, arguments:Array<IrType>, result:IrType):Void {
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

	static function abiCompatible(actual:IrType, expected:IrType):Bool
		return switch expected {
			case Array(Dyn): switch actual {
					case Array(element): isReference(element);
					default: false;
				};
			case Dyn: isReference(actual);
			default: false;
		};

	static function compatibleType(actual:IrType, expected:IrType, objects:Map<String, IrObject>, interfaces:Map<String, IrInterface>):Bool {
		if (sameType(actual, expected))
			return true;
		if (abiCompatible(actual, expected))
			return true;
		return switch actual {
			case Obj(actualName): switch expected {
					case Obj(_):
						if (!objects.exists(actualName)) false; else {
							var base = objects.get(actualName).base;
							base != null && compatibleType(Obj(base), expected, objects, interfaces)
							;
						}
					case Dyn: true;
					default: false;
				};
			case Virtual(actualName): switch expected {
					case Virtual(expectedName): interfaceExtends(actualName, expectedName, interfaces);
					case Dyn: true;
					default: false;
				};
			case Array(actualElement): switch expected {
					case Array(expectedElement): expectedElement == Dyn ? isReference(actualElement) : sameType(actualElement, expectedElement);
					case Dyn: true;
					default: false;
				};
			case Bytes, Function(_, _): switch expected {
					case Dyn: true;
					default: false;
				};
			default: false;
		};
	}

	static function interfaceExtends(actual:String, expected:String, interfaces:Map<String, IrInterface>):Bool {
		if (actual == expected)
			return true;
		if (!interfaces.exists(actual))
			return false;
		var declaration = interfaces.get(actual);
		for (base in declaration.bases)
			if (interfaceExtends(base, expected, interfaces))
				return true;
		return false;
	}
}
