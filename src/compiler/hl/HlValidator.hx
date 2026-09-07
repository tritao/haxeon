package compiler.hl;

import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction.HlInstruction;

/** Validates an in-memory HashLink module before serialization. */
class HlValidator {
	public static function validate(code:HlCode):Void {
		if (code.types.length == 0)
			throw "HL module has no types";

		for (type in code.types) {
			switch type {
				case Simple(kind):
					if (kind == HlType.Ref || kind == HlType.Null || kind == HlType.Packed)
						throw 'HashLink type $kind requires a parameter';
				case Parameterized(kind, parameter):
					if (kind != HlType.Ref && kind != HlType.Null && kind != HlType.Packed)
						throw 'Unsupported parameterized HashLink type $kind';
					requireType(code, parameter, "parameterized type argument");
				case Abstract(name):
					requireString(code, name, "abstract name");
				case Enum(name, global, constructors):
					requireString(code, name, "enum name");
					if (global < 0)
						throw 'Invalid enum global $global';
					for (constructor in constructors) {
						requireString(code, constructor.name, "enum constructor name");
						for (param in constructor.params)
							requireType(code, param, "enum constructor parameter");
					}
				case Function(arguments, result):
					for (argument in arguments)
						requireType(code, argument, "function type argument");
					requireType(code, result, "function type result");
				case Object(name, base, global, fields, methods, bindings):
					requireString(code, name, "object name");
					if (base >= 0)
						requireType(code, base, "object base");
					if (global > code.globals.length && global != 0)
						throw 'Invalid object global $global';
					for (field in fields) {
						requireString(code, field.name, "object field name");
						requireType(code, field.type, "object field type");
					}
					for (method in methods) {
						requireString(code, method.name, "object method name");
						requireFunctionIndex(code, method.functionIndex, "object method");
						if (method.prototype < 0)
							throw 'Invalid object method prototype ${method.prototype}';
					}
				case Structure(name, global, fields, methods, bindings):
					requireString(code, name, "structure name");
					if (global > code.globals.length && global != 0)
						throw 'Invalid structure global $global';
					for (field in fields) {
						requireString(code, field.name, "structure field name");
						requireType(code, field.type, "structure field type");
					}
					for (method in methods) {
						requireString(code, method.name, "structure method name");
						requireFunctionIndex(code, method.functionIndex, "structure method");
						if (method.prototype < 0)
							throw 'Invalid structure method prototype ${method.prototype}';
					}
				case Virtual(fields):
					for (field in fields) {
						requireString(code, field.name, "virtual field name");
						requireType(code, field.type, "virtual field type");
					}
			}
		}
		for (global in code.globals)
			requireType(code, global, "global");

		var functionIndices = new Map<Int, Bool>();
		for (native in code.natives) {
			requireType(code, native.type, 'native ${native.functionIndex}');
			requireString(code, native.library, 'native library');
			requireString(code, native.name, 'native name');
			addFunctionIndex(functionIndices, native.functionIndex);
		}
		for (fn in code.functions) {
			requireType(code, fn.type, 'function ${fn.functionIndex}');
			addFunctionIndex(functionIndices, fn.functionIndex);
		}
		for (fn in code.functions) {
			if (fn.debugLocations.length != 0 && fn.debugLocations.length != fn.opcodes.length)
				throw 'Debug location count does not match opcodes in function ${fn.functionIndex}';
			for (location in fn.debugLocations)
				if (location.path == null || location.line < 1)
					throw 'Invalid debug location in function ${fn.functionIndex}';
			for (registerType in fn.registers)
				requireType(code, registerType, 'register in function ${fn.functionIndex}');
			validateInstructions(code, fn, functionIndices);
		}
		if (!functionIndices.exists(code.entryPoint))
			throw 'Entry point ${code.entryPoint} is not a function';
		var debugSections:Map<String, Bool> = [];
		for (section in code.debugSections) {
			if (section.kind <= 0 || section.version <= 0 || section.flags < 0 || section.payload == null)
				throw "Invalid HLB debug section";
			var key = section.kind + ":" + section.version;
			if (debugSections.exists(key))
				throw 'Duplicate HLB debug section $key';
			debugSections.set(key, true);
		}
	}

	static function addFunctionIndex(indices:Map<Int, Bool>, index:Int):Void {
		if (index < 0)
			throw 'Negative function index $index';
		if (indices.exists(index))
			throw 'Duplicate function index $index';
		indices.set(index, true);
	}

	static function validateInstructions(code:HlCode, fn:HlFunction, functionIndices:Map<Int, Bool>):Void {
		var labels = collectLabels(fn);
		for (instruction in fn.opcodes) {
			switch instruction {
				case Move(destination, source):
					requireRegister(fn, destination);
					requireRegister(fn, source);
				case LoadInt(destination, constant):
					requireRegister(fn, destination);
					if (constant < 0 || constant >= code.ints.length)
						throw 'Invalid integer constant $constant in function ${fn.functionIndex}';
				case LoadFloat(destination, constant):
					requireRegister(fn, destination);
					if (constant < 0 || constant >= code.floats.length)
						throw 'Invalid float constant $constant in function ${fn.functionIndex}';
				case LoadString(destination, constant):
					requireRegister(fn, destination);
					requireString(code, constant, 'function ${fn.functionIndex}');
				case LoadBool(destination, _):
					requireRegister(fn, destination);
				case LoadNull(destination):
					requireRegister(fn, destination);
				case LoadType(destination, type):
					requireRegister(fn, destination);
					requireType(code, type, 'type literal in function ${fn.functionIndex}');
				case ToDyn(destination, source):
					requireRegister(fn, destination);
					requireRegister(fn, source);
				case SafeCast(destination, source):
					requireRegister(fn, destination);
					requireRegister(fn, source);
				case Trap(destination, target):
					requireRegister(fn, destination);
					if (!labels.exists(target))
						throw 'Unknown label "$target" in function ${fn.functionIndex}';
				case EndTrap(destination):
					requireRegister(fn, destination);
				case GlobalGet(destination, global):
					requireRegister(fn, destination);
					requireGlobal(code, global, 'function ${fn.functionIndex}');
				case GlobalSet(global, source):
					requireGlobal(code, global, 'function ${fn.functionIndex}');
					requireRegister(fn, source);
				case Add(destination, left, right):
					requireRegister(fn, destination);
					requireRegister(fn, left);
					requireRegister(fn, right);
				case Sub(destination, left, right):
					requireRegister(fn, destination);
					requireRegister(fn, left);
					requireRegister(fn, right);
				case Mul(destination, left, right), Div(destination, left, right):
					requireRegister(fn, destination);
					requireRegister(fn, left);
					requireRegister(fn, right);
				case Mod(destination, left, right), BitAnd(destination, left, right), BitXor(destination, left, right), BitOr(destination, left, right),
					ShiftLeft(destination, left, right), ShiftRight(destination, left, right), UnsignedShiftRight(destination, left, right):
					requireRegister(fn, destination);
					requireRegister(fn, left);
					requireRegister(fn, right);
				case Call0(destination, functionIndex):
					requireRegister(fn, destination);
					requireCallable(functionIndices, functionIndex, fn.functionIndex);
				case Call1(destination, functionIndex, argument):
					requireRegister(fn, destination);
					requireRegister(fn, argument);
					requireCallable(functionIndices, functionIndex, fn.functionIndex);
				case Call2(destination, functionIndex, argument1, argument2):
					requireRegister(fn, destination);
					requireRegister(fn, argument1);
					requireRegister(fn, argument2);
					requireCallable(functionIndices, functionIndex, fn.functionIndex);
				case CallN(destination, functionIndex, arguments):
					requireRegister(fn, destination);
					requireCallable(functionIndices, functionIndex, fn.functionIndex);
					for (argument in arguments)
						requireRegister(fn, argument);
				case StaticClosure(destination, functionIndex):
					requireRegister(fn, destination);
					requireCallable(functionIndices, functionIndex, fn.functionIndex);
				case InstanceClosure(destination, functionIndex, receiver):
					requireRegister(fn, destination);
					requireRegister(fn, receiver);
					requireCallable(functionIndices, functionIndex, fn.functionIndex);
				case CallClosure(destination, closure, arguments):
					requireRegister(fn, destination);
					requireRegister(fn, closure);
					for (argument in arguments)
						requireRegister(fn, argument);
				case ToVirtual(destination, source):
					requireRegister(fn, destination);
					requireRegister(fn, source);
				case CallMethod(destination, method, arguments):
					requireRegister(fn, destination);
					if (method < 0)
						throw 'Invalid object method $method in function ${fn.functionIndex}';
					for (argument in arguments)
						requireRegister(fn, argument);
				case New(destination, type, _):
					requireRegister(fn, destination);
					requireType(code, type, 'object allocation in function ${fn.functionIndex}');
				case FieldGet(destination, object, field):
					requireRegister(fn, destination);
					requireRegister(fn, object);
					if (field < 0)
						throw 'Invalid object field $field in function ${fn.functionIndex}';
				case FieldSet(object, field, source):
					requireRegister(fn, object);
					requireRegister(fn, source);
					if (field < 0)
						throw 'Invalid object field $field in function ${fn.functionIndex}';
				case ArrayGet(destination, array, index):
					requireRegister(fn, destination);
					requireRegister(fn, array);
					requireRegister(fn, index);
				case ArraySet(array, index, source):
					requireRegister(fn, array);
					requireRegister(fn, index);
					requireRegister(fn, source);
				case ArraySize(destination, array):
					requireRegister(fn, destination);
					requireRegister(fn, array);
				case MakeEnum(destination, constructor, arguments):
					requireRegister(fn, destination);
					if (constructor < 0)
						throw 'Invalid enum constructor $constructor in function ${fn.functionIndex}';
					for (argument in arguments)
						requireRegister(fn, argument);
				case EnumIndex(destination, value):
					requireRegister(fn, destination);
					requireRegister(fn, value);
				case EnumField(destination, value, constructor, field):
					requireRegister(fn, destination);
					requireRegister(fn, value);
					if (constructor < 0 || field < 0)
						throw 'Invalid enum field ${constructor}.${field} in function ${fn.functionIndex}';
				case JumpSignedLessOrEqual(left, right, target):
					requireRegister(fn, left);
					requireRegister(fn, right);
					if (!labels.exists(target))
						throw 'Unknown label "$target" in function ${fn.functionIndex}';
				case JumpSignedLess(left, right, target), JumpEqual(left, right, target):
					requireRegister(fn, left);
					requireRegister(fn, right);
					if (!labels.exists(target))
						throw 'Unknown label "$target" in function ${fn.functionIndex}';
				case JumpTrue(condition, target):
					requireRegister(fn, condition);
					if (!labels.exists(target))
						throw 'Unknown label "$target" in function ${fn.functionIndex}';
				case Jump(target):
					if (!labels.exists(target))
						throw 'Unknown label "$target" in function ${fn.functionIndex}';
				case Label(_):
				case Return(register):
					requireRegister(fn, register);
				case Throw(register), Rethrow(register):
					requireRegister(fn, register);
			}
		}
	}

	public static function collectLabels(fn:HlFunction):Map<String, Int> {
		var labels = new Map<String, Int>();
		var position = 0;
		for (instruction in fn.opcodes) {
			switch instruction {
				case Label(name):
					if (labels.exists(name))
						throw 'Duplicate label "$name" in function ${fn.functionIndex}';
					labels.set(name, position);
					position++;
				default:
					position++;
			}
		}
		return labels;
	}

	static function requireCallable(indices:Map<Int, Bool>, callee:Int, caller:Int):Void {
		if (!indices.exists(callee))
			throw 'Function $caller calls unknown function $callee';
	}

	static function requireFunctionIndex(code:HlCode, index:Int, context:String):Void {
		if (index < 0)
			throw 'Invalid function index $index for $context';
	}

	static function requireRegister(fn:HlFunction, register:Int):Void {
		if (register < 0 || register >= fn.registers.length)
			throw 'Invalid register $register in function ${fn.functionIndex}';
	}

	static function requireType(code:HlCode, type:Int, context:String):Void {
		if (type < 0 || type >= code.types.length)
			throw 'Invalid type $type for $context';
	}

	static function requireString(code:HlCode, string:Int, context:String):Void {
		if (string < 0 || string >= code.strings.length)
			throw 'Invalid string $string for $context';
	}

	static function requireGlobal(code:HlCode, global:Int, context:String):Void {
		if (global < 0 || global >= code.globals.length)
			throw 'Invalid global $global for $context';
	}
}
