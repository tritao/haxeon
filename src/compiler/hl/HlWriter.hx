package compiler.hl;

import haxe.io.Bytes as HaxeBytes;
import haxe.io.BytesOutput;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlFunction.HlDebugLocation;

/** Encoded opcode bytes paired with unresolved symbolic branch targets. */
private typedef EncodedInstruction = {
	final opcode:HlOpcode;
	final operands:Array<Int>;
}

/** Serializes the in-memory HashLink model using canonical HLB encodings. */
class HlWriter {
	final output:BytesOutput;
	var hasDebug:Bool = false;
	var debugFiles:Array<String> = [];
	var debugFileIndices:Map<String, Int> = [];

	public function new() {
		output = new BytesOutput();
		output.bigEndian = false;
	}

	public static function encode(code:HlCode):HaxeBytes {
		HlValidator.validate(code);
		var writer = new HlWriter();
		writer.writeCode(code);
		return writer.output.getBytes();
	}

	/** Public because index encoding is part of the HLB format contract. */
	public static function encodeIndex(value:Int):HaxeBytes {
		var writer = new HlWriter();
		writer.writeIndex(value);
		return writer.output.getBytes();
	}

	/** Encodes one function using its canonical HLB function representation. */
	public static function encodeFunction(fn:HlFunction):HaxeBytes {
		var writer = new HlWriter();
		writer.writeFunction(fn);
		return writer.output.getBytes();
	}

	function writeCode(code:HlCode):Void {
		prepareDebugFiles(code);
		output.writeString("HLB");
		output.writeByte(HlCode.VERSION);
		writeUnsignedIndex(hasDebug ? 1 : 0);
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
		if (hasDebug) {
			writeUnsignedIndex(debugFiles.length);
			writeStrings(debugFiles);
		}

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
			var bytes = HaxeBytes.ofString(value);
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
		if (hasDebug) {
			writeDebugLocations(fn);
			writeUnsignedIndex(0); // local-variable assignments
		}
	}

	function prepareDebugFiles(code:HlCode):Void {
		hasDebug = false;
		for (fn in code.functions)
			if (fn.debugLocations.length > 0)
				hasDebug = true;
		if (!hasDebug)
			return;
		for (fn in code.functions) {
			if (fn.debugLocations.length == 0) {
				internDebugFile("<generated>");
				continue;
			}
			for (location in fn.debugLocations)
				internDebugFile(location.path);
		}
	}

	function internDebugFile(path:String):Int {
		if (debugFileIndices.exists(path))
			return debugFileIndices.get(path);
		var index = debugFiles.length;
		if (index > 0x7FFF)
			throw "Too many HashLink debug files";
		debugFiles.push(path);
		debugFileIndices.set(path, index);
		return index;
	}

	function writeDebugLocations(fn:HlFunction):Void {
		var currentFile = -1;
		for (index in 0...fn.opcodes.length) {
			var location:HlDebugLocation = fn.debugLocations.length == 0 ? cast {path: "<generated>", line: 1} : fn.debugLocations[index];
			if (location.line > 0x1FFFFF)
				throw 'Debug line ${location.line} exceeds the HashLink format limit';
			var file = debugFileIndices.get(location.path);
			if (file != currentFile) {
				output.writeByte(((file >> 8) << 1) | 1);
				output.writeByte(file & 0xFF);
				currentFile = file;
			}
			output.writeByte((location.line & 0x1F) << 3);
			output.writeByte((location.line >> 5) & 0xFF);
			output.writeByte((location.line >> 13) & 0xFF);
		}
	}

	function lowerInstructions(fn:HlFunction):Array<EncodedInstruction> {
		var labels = HlValidator.collectLabels(fn);
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
