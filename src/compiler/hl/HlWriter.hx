package compiler.hl;

import haxe.io.Bytes;
import haxe.io.BytesOutput;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction.HlInstruction;

/** Encoded opcode bytes paired with unresolved symbolic branch targets. */
private typedef EncodedInstruction = {
	final opcode:HlOpcode;
	final operands:Array<Int>;
}

/** Serializes the in-memory HashLink model using canonical HLB encodings. */
class HlWriter {
	final output:BytesOutput;

	public function new() {
		output = new BytesOutput();
		output.bigEndian = false;
	}

	public static function encode(code:HlCode):Bytes {
		validate(code);
		var writer = new HlWriter();
		writer.writeCode(code);
		return writer.output.getBytes();
	}

	/** Public because index encoding is part of the HLB format contract. */
	public static function encodeIndex(value:Int):Bytes {
		var writer = new HlWriter();
		writer.writeIndex(value);
		return writer.output.getBytes();
	}

	/** Encodes one function using its canonical HLB function representation. */
	public static function encodeFunction(fn:HlFunction):Bytes {
		var writer = new HlWriter();
		writer.writeFunction(fn);
		return writer.output.getBytes();
	}

	static function validate(code:HlCode):Void {
		if (code.types.length == 0)
			throw "HL module has no types";

		for (type in code.types) {
			switch type {
				case Simple(kind):
					if (kind == HlType.Ref || kind == HlType.Null)
						throw 'HashLink type $kind requires a parameter';
				case Parameterized(kind, parameter):
					if (kind != HlType.Ref && kind != HlType.Null)
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
			for (registerType in fn.registers)
				requireType(code, registerType, 'register in function ${fn.functionIndex}');
			validateInstructions(code, fn, functionIndices);
		}
		if (!functionIndices.exists(code.entryPoint))
			throw 'Entry point ${code.entryPoint} is not a function';
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

	static function collectLabels(fn:HlFunction):Map<String, Int> {
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

	function writeCode(code:HlCode):Void {
		output.writeString("HLB");
		output.writeByte(HlCode.VERSION);
		writeUnsignedIndex(0); // flags: no debug information
		writeUnsignedIndex(code.ints.length);
		writeUnsignedIndex(code.floats.length);
		writeUnsignedIndex(code.strings.length);
		writeUnsignedIndex(0); // byte blobs
		writeUnsignedIndex(code.types.length);
		writeUnsignedIndex(code.globals.length);
		writeUnsignedIndex(code.natives.length);
		writeUnsignedIndex(code.functions.length);
		writeUnsignedIndex(0); // constants
		writeUnsignedIndex(code.entryPoint);

		for (value in code.ints)
			output.writeInt32(value);
		for (value in code.floats)
			output.writeDouble(value);
		writeStrings(code.strings);
		output.writeInt32(0); // byte blob storage size

		for (type in code.types)
			writeType(type);
		// HashLink's decoder reads the global type table before natives.
		for (global in code.globals)
			writeIndex(global);
		for (native in code.natives) {
			writeIndex(native.library);
			writeIndex(native.name);
			writeIndex(native.type);
			writeUnsignedIndex(native.functionIndex);
		}
		for (fn in code.functions)
			writeFunction(fn);
	}

	function writeStrings(strings:Array<String>):Void {
		var data = new BytesOutput();
		var lengths:Array<Int> = [];
		for (value in strings) {
			var bytes = Bytes.ofString(value);
			lengths.push(bytes.length);
			data.write(bytes);
			data.writeByte(0);
		}
		var bytes = data.getBytes();
		output.writeInt32(bytes.length);
		output.write(bytes);
		for (length in lengths)
			writeUnsignedIndex(length);
	}

	function writeType(type:HlTypeDef):Void {
		switch type {
			case Simple(kind):
				output.writeByte(kind);
			case Parameterized(kind, parameter):
				if (kind != HlType.Ref && kind != HlType.Null)
					throw 'Unsupported parameterized HashLink type $kind';
				output.writeByte(kind);
				writeIndex(parameter);
			case Abstract(name):
				output.writeByte(HlType.Abstract);
				writeIndex(name);
			case Function(arguments, result):
				if (arguments.length > 255)
					throw "HL function types support at most 255 arguments";
				output.writeByte(HlType.Fun);
				output.writeByte(arguments.length);
				for (argument in arguments)
					writeIndex(argument);
				writeIndex(result);
			case Object(name, base, global, fields, methods, bindings):
				output.writeByte(HlType.Obj);
				writeIndex(name);
				writeIndex(base);
				writeUnsignedIndex(global);
				writeUnsignedIndex(fields.length);
				writeUnsignedIndex(methods.length);
				writeUnsignedIndex(Std.int(bindings.length / 2));
				for (field in fields) {
					writeIndex(field.name);
					writeIndex(field.type);
				}
				for (method in methods) {
					writeIndex(method.name);
					writeUnsignedIndex(method.functionIndex);
					writeIndex(method.prototype);
				}
				for (binding in bindings)
					writeUnsignedIndex(binding);
			case Virtual(fields):
				output.writeByte(HlType.Virtual);
				writeUnsignedIndex(fields.length);
				for (field in fields) {
					writeIndex(field.name);
					writeIndex(field.type);
				}
			case Enum(name, global, constructors):
				output.writeByte(HlType.Enum);
				writeIndex(name);
				writeUnsignedIndex(global);
				writeUnsignedIndex(constructors.length);
				for (constructor in constructors) {
					writeIndex(constructor.name);
					writeUnsignedIndex(constructor.params.length);
					for (param in constructor.params)
						writeIndex(param);
				}
		}
	}

	function writeFunction(fn:HlFunction):Void {
		var instructions = lowerInstructions(fn);
		writeIndex(fn.type);
		writeUnsignedIndex(fn.functionIndex);
		writeUnsignedIndex(fn.registers.length);
		writeUnsignedIndex(instructions.length);
		for (type in fn.registers)
			writeIndex(type);
		for (instruction in instructions)
			writeOpcode(instruction.opcode, instruction.operands);
	}

	function lowerInstructions(fn:HlFunction):Array<EncodedInstruction> {
		var labels = collectLabels(fn);
		var result:Array<EncodedInstruction> = [];
		for (instruction in fn.opcodes) {
			var encoded:EncodedInstruction = switch instruction {
				case Move(destination, source): {opcode: HlOpcode.Mov, operands: [destination, source]};
				case LoadInt(destination, constant):
					{opcode: HlOpcode.Int, operands: [destination, constant]};
				case LoadFloat(destination, constant):
					{opcode: HlOpcode.Float, operands: [destination, constant]};
				case LoadString(destination, constant):
					{opcode: HlOpcode.String, operands: [destination, constant]};
				case LoadBool(destination, value):
					{opcode: HlOpcode.Bool, operands: [destination, value ? 1 : 0]};
				case LoadNull(destination):
					{opcode: HlOpcode.Null, operands: [destination]};
				case LoadType(destination, type):
					{opcode: HlOpcode.Type, operands: [destination, type]};
				case ToDyn(destination, source):
					{opcode: HlOpcode.ToDyn, operands: [destination, source]};
				case SafeCast(destination, source):
					{opcode: HlOpcode.SafeCast, operands: [destination, source]};
				case GlobalGet(destination, global):
					{opcode: HlOpcode.GetGlobal, operands: [destination, global]};
				case GlobalSet(global, source):
					{opcode: HlOpcode.SetGlobal, operands: [global, source]};
				case Add(destination, left, right):
					{opcode: HlOpcode.Add, operands: [destination, left, right]};
				case Sub(destination, left, right):
					{opcode: HlOpcode.Sub, operands: [destination, left, right]};
				case Mul(destination, left, right): {opcode: HlOpcode.Mul, operands: [destination, left, right]};
				case Div(destination, left, right): {opcode: HlOpcode.SDiv, operands: [destination, left, right]};
				case Mod(destination, left, right): {opcode: HlOpcode.SMod, operands: [destination, left, right]};
				case BitAnd(destination, left, right): {opcode: HlOpcode.And, operands: [destination, left, right]};
				case BitXor(destination, left, right): {opcode: HlOpcode.Xor, operands: [destination, left, right]};
				case BitOr(destination, left, right): {opcode: HlOpcode.Or, operands: [destination, left, right]};
				case ShiftLeft(destination, left, right): {opcode: HlOpcode.Shl, operands: [destination, left, right]};
				case ShiftRight(destination, left, right): {opcode: HlOpcode.SShr, operands: [destination, left, right]};
				case UnsignedShiftRight(destination, left, right): {opcode: HlOpcode.UShr, operands: [destination, left, right]};
				case Call0(destination, functionIndex):
					{opcode: HlOpcode.Call0, operands: [destination, functionIndex]};
				case Call1(destination, functionIndex, argument):
					{opcode: HlOpcode.Call1, operands: [destination, functionIndex, argument]};
				case Call2(destination, functionIndex, argument1, argument2):
					{opcode: HlOpcode.Call2, operands: [destination, functionIndex, argument1, argument2]};
				case CallN(destination, functionIndex, arguments):
					{opcode: HlOpcode.CallN, operands: [destination, functionIndex, arguments.length].concat(arguments)};
				case StaticClosure(destination, functionIndex):
					{opcode: HlOpcode.StaticClosure, operands: [destination, functionIndex]};
				case InstanceClosure(destination, functionIndex, receiver):
					{opcode: HlOpcode.InstanceClosure, operands: [destination, functionIndex, receiver]};
				case CallClosure(destination, closure, arguments):
					{opcode: HlOpcode.CallClosure, operands: [destination, closure, arguments.length].concat(arguments)};
				case ToVirtual(destination, source):
					{opcode: HlOpcode.ToVirtual, operands: [destination, source]};
				case CallMethod(destination, method, arguments):
					{opcode: HlOpcode.CallMethod, operands: [destination, method, arguments.length].concat(arguments)};
				case New(destination, _, _):
					// ONew has no encoded type operand. HashLink derives the
					// allocation type from the destination register's type.
					{opcode: HlOpcode.New, operands: [destination]};
				case FieldGet(destination, object, field):
					{opcode: HlOpcode.Field, operands: [destination, object, field]};
				case FieldSet(object, field, source):
					{opcode: HlOpcode.SetField, operands: [object, field, source]};
				case ArrayGet(destination, array, index):
					{opcode: HlOpcode.GetArray, operands: [destination, array, index]};
				case ArraySet(array, index, source):
					{opcode: HlOpcode.SetArray, operands: [array, index, source]};
				case ArraySize(destination, array):
					{opcode: HlOpcode.ArraySize, operands: [destination, array]};
				case MakeEnum(destination, constructor, arguments):
					{opcode: HlOpcode.MakeEnum, operands: [destination, constructor, arguments.length].concat(arguments)};
				case EnumIndex(destination, value):
					{opcode: HlOpcode.EnumIndex, operands: [destination, value]};
				case EnumField(destination, value, constructor, field):
					{opcode: HlOpcode.EnumField, operands: [destination, value, constructor, field]};
				case JumpSignedLessOrEqual(left, right, target):
					var targetPosition = labels.get(target);
					{opcode: HlOpcode.JSLte, operands: [left, right, targetPosition - (result.length + 1)]};
				case JumpSignedLess(left, right, target):
					var targetPosition = labels.get(target);
					{opcode: HlOpcode.JSLt, operands: [left, right, targetPosition - (result.length + 1)]};
				case JumpEqual(left, right, target):
					var targetPosition = labels.get(target);
					{opcode: HlOpcode.JEq, operands: [left, right, targetPosition - (result.length + 1)]};
				case JumpTrue(condition, target):
					var targetPosition = labels.get(target);
					{opcode: HlOpcode.JTrue, operands: [condition, targetPosition - (result.length + 1)]};
				case Jump(target):
					var targetPosition = labels.get(target);
					{opcode: HlOpcode.JAlways, operands: [targetPosition - (result.length + 1)]};
				case Trap(destination, target):
					var targetPosition = labels.get(target);
					{opcode: HlOpcode.Trap, operands: [destination, targetPosition - (result.length + 1)]};
				case EndTrap(destination):
					{opcode: HlOpcode.EndTrap, operands: [destination]};
				case Label(_): {opcode: HlOpcode.Label, operands: []};
				case Return(register):
					{opcode: HlOpcode.Ret, operands: [register]};
				case Throw(register):
					{opcode: HlOpcode.Throw, operands: [register]};
				case Rethrow(register):
					{opcode: HlOpcode.Rethrow, operands: [register]};
			}
			result.push(encoded);
		}
		return result;
	}

	function writeOpcode(opcode:HlOpcode, operands:Array<Int>):Void {
		output.writeByte(opcode);
		for (operand in operands)
			writeIndex(operand);
	}

	function writeUnsignedIndex(value:Int):Void {
		if (value < 0)
			throw 'Expected unsigned index, got $value';
		writeIndex(value);
	}

	/** Inverse of HashLink's signed variable-width hl_read_index. */
	function writeIndex(value:Int):Void {
		var negative = value < 0;
		var magnitude = negative ? -value : value;
		if (magnitude < 0x80 && !negative) {
			output.writeByte(magnitude);
		} else if (magnitude < 0x2000) {
			output.writeByte(0x80 | (negative ? 0x20 : 0) | (magnitude >> 8));
			output.writeByte(magnitude & 0xFF);
		} else if (magnitude < 0x20000000) {
			output.writeByte(0xC0 | (negative ? 0x20 : 0) | (magnitude >> 24));
			output.writeByte((magnitude >> 16) & 0xFF);
			output.writeByte((magnitude >> 8) & 0xFF);
			output.writeByte(magnitude & 0xFF);
		} else {
			throw 'HL index is out of range: $value';
		}
	}
}
