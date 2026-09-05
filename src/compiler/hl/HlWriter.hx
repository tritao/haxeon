package compiler.hl;

import haxe.io.Bytes;
import haxe.io.BytesOutput;
import haxe.io.Encoding;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction.HlInstruction;

private typedef EncodedInstruction = {
	final opcode:HlOpcode;
	final operands:Array<Int>;
}

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
				case Simple(_):
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
						requireType(code, method.prototype, "object method prototype");
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

	function writeCode(code:HlCode):Void {
		output.writeString("HLB", Encoding.UTF8);
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
		var lengths = [];
		for (value in strings) {
			var bytes = Bytes.ofString(value, Encoding.UTF8);
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
				case Add(destination, left, right):
					{opcode: HlOpcode.Add, operands: [destination, left, right]};
				case Sub(destination, left, right):
					{opcode: HlOpcode.Sub, operands: [destination, left, right]};
				case Mul(destination, left, right): {opcode: HlOpcode.Mul, operands: [destination, left, right]};
				case Div(destination, left, right): {opcode: HlOpcode.SDiv, operands: [destination, left, right]};
				case Call0(destination, functionIndex):
					{opcode: HlOpcode.Call0, operands: [destination, functionIndex]};
				case Call1(destination, functionIndex, argument):
					{opcode: HlOpcode.Call1, operands: [destination, functionIndex, argument]};
				case Call2(destination, functionIndex, argument1, argument2):
					{opcode: HlOpcode.Call2, operands: [destination, functionIndex, argument1, argument2]};
				case New(destination, _, _):
					// ONew has no encoded type operand. HashLink derives the
					// allocation type from the destination register's type.
					{opcode: HlOpcode.New, operands: [destination]};
				case FieldGet(destination, object, field):
					{opcode: HlOpcode.Field, operands: [destination, object, field]};
				case FieldSet(object, field, source):
					{opcode: HlOpcode.SetField, operands: [object, field, source]};
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
				case Label(_): {opcode: HlOpcode.Label, operands: []};
				case Return(register):
					{opcode: HlOpcode.Ret, operands: [register]};
			}
			if (encoded != null)
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
