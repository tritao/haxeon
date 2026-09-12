package compiler.ir.codec;

import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import haxe.io.Bytes as HaxeBytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import compiler.ir.codec.IrTypeCodec;
import compiler.ir.codec.IrValueTableCodec;

/** Closed, versioned encoding for every persisted IR instruction operand. */
class IrInstructionCodec {
	static final CONSTRUCTORS:Map<String, Bool> = [
		"Phi" => true,
		"ConstVoid" => true,
		"ConstInt" => true,
		"ConstFloat" => true,
		"ConstString" => true,
		"ConstBool" => true,
		"ConstNull" => true,
		"TypeValue" => true,
		"ToDyn" => true,
		"IntToFloat" => true,
		"IntToInt64" => true,
		"FloatToInt" => true,
		"SafeCast" => true,
		"BeginTry" => true,
		"EndTry" => true,
		"Catch" => true,
		"GlobalGet" => true,
		"GlobalSet" => true,
		"Add" => true,
		"Sub" => true,
		"Mul" => true,
		"Div" => true,
		"Mod" => true,
		"BitAnd" => true,
		"BitXor" => true,
		"BitOr" => true,
		"ShiftLeft" => true,
		"ShiftRight" => true,
		"UnsignedShiftRight" => true,
		"Less" => true,
		"LessEqual" => true,
		"Equal" => true,
		"Call" => true,
		"CNativeCall" => true,
		"StaticClosure" => true,
		"InstanceClosure" => true,
		"CallClosure" => true,
		"ToVirtual" => true,
		"MethodCall" => true,
		"NewObject" => true,
		"FieldGet" => true,
		"FieldSet" => true,
		"ArrayGet" => true,
		"ArraySet" => true,
		"ArraySize" => true,
		"MakeEnum" => true,
		"EnumIndex" => true,
		"EnumField" => true
	];

	public static function encode(instruction:IrInstruction):HaxeBytes {
		var output = new BytesOutput();
		output.bigEndian = false;
		output.writeString("IRI");
		output.writeByte(1);
		write(output, instruction);
		return output.getBytes();
	}

	public static function decode(bytes:HaxeBytes, values:Map<Int, IrValue>):IrInstruction {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != "IRI" || input.readByte() != 1)
				throw "Invalid IR instruction state";
			var result = read(input, bytes.length, values);
			if (input.position != bytes.length)
				throw "Trailing IR instruction state data";
			return result;
		} catch (error:haxe.io.Eof) {
			throw "Truncated IR instruction state";
		} catch (error:String) {
			if (StringTools.startsWith(error, "Invalid IR") || error == "Unknown IR instruction")
				throw error;
			throw "Invalid IR instruction operands";
		} catch (_:Dynamic) {
			throw "Invalid IR instruction operands";
		}
	}

	public static function write(output:BytesOutput, instruction:IrInstruction):Void {
		switch instruction {
			case Phi(value, inputs):
				begin(output, "Phi", 2);
				writeValue(output, value);
				writePhiInputs(output, inputs);
			case ConstVoid(value):
				begin(output, "ConstVoid", 1);
				writeValue(output, value);
			case ConstInt(value, constant):
				begin(output, "ConstInt", 2);
				writeValue(output, value);
				writeInt(output, constant);
			case ConstFloat(value, constant):
				begin(output, "ConstFloat", 2);
				writeValue(output, value);
				writeFloat(output, constant);
			case ConstString(value, constant):
				begin(output, "ConstString", 2);
				writeValue(output, value);
				writeText(output, constant);
			case ConstBool(value, constant):
				begin(output, "ConstBool", 2);
				writeValue(output, value);
				writeBool(output, constant);
			case ConstNull(value):
				begin(output, "ConstNull", 1);
				writeValue(output, value);
			case TypeValue(value, type):
				begin(output, "TypeValue", 2);
				writeValue(output, value);
				writeType(output, type);
			case ToDyn(outputValue, value):
				writeTwoValues(output, "ToDyn", outputValue, value);
			case IntToFloat(outputValue, value):
				writeTwoValues(output, "IntToFloat", outputValue, value);
			case IntToInt64(outputValue, value):
				writeTwoValues(output, "IntToInt64", outputValue, value);
			case FloatToInt(outputValue, value):
				writeTwoValues(output, "FloatToInt", outputValue, value);
			case SafeCast(outputValue, value):
				writeTwoValues(output, "SafeCast", outputValue, value);
			case BeginTry(catchBlock, afterBlock):
				begin(output, "BeginTry", 2);
				writeInt(output, catchBlock);
				writeInt(output, afterBlock);
			case EndTry(catchBlock):
				begin(output, "EndTry", 1);
				writeInt(output, catchBlock);
			case Catch(value):
				begin(output, "Catch", 1);
				writeValue(output, value);
			case GlobalGet(value, name):
				begin(output, "GlobalGet", 2);
				writeValue(output, value);
				writeText(output, name);
			case GlobalSet(name, value):
				begin(output, "GlobalSet", 2);
				writeText(output, name);
				writeValue(output, value);
			case Add(value, left, right):
				writeThreeValues(output, "Add", value, left, right);
			case Sub(value, left, right):
				writeThreeValues(output, "Sub", value, left, right);
			case Mul(value, left, right):
				writeThreeValues(output, "Mul", value, left, right);
			case Div(value, left, right):
				writeThreeValues(output, "Div", value, left, right);
			case Mod(value, left, right):
				writeThreeValues(output, "Mod", value, left, right);
			case BitAnd(value, left, right):
				writeThreeValues(output, "BitAnd", value, left, right);
			case BitXor(value, left, right):
				writeThreeValues(output, "BitXor", value, left, right);
			case BitOr(value, left, right):
				writeThreeValues(output, "BitOr", value, left, right);
			case ShiftLeft(value, left, right):
				writeThreeValues(output, "ShiftLeft", value, left, right);
			case ShiftRight(value, left, right):
				writeThreeValues(output, "ShiftRight", value, left, right);
			case UnsignedShiftRight(value, left, right):
				writeThreeValues(output, "UnsignedShiftRight", value, left, right);
			case Less(value, left, right):
				writeThreeValues(output, "Less", value, left, right);
			case LessEqual(value, left, right):
				writeThreeValues(output, "LessEqual", value, left, right);
			case Equal(value, left, right):
				writeThreeValues(output, "Equal", value, left, right);
			case Call(value, name, arguments):
				begin(output, "Call", 3);
				writeValue(output, value);
				writeText(output, name);
				writeValues(output, arguments);
			case CNativeCall(value, name, arguments):
				begin(output, "CNativeCall", 3);
				writeValue(output, value);
				writeText(output, name);
				writeValues(output, arguments);
			case StaticClosure(value, name):
				begin(output, "StaticClosure", 2);
				writeValue(output, value);
				writeText(output, name);
			case InstanceClosure(value, name, receiver):
				begin(output, "InstanceClosure", 3);
				writeValue(output, value);
				writeText(output, name);
				writeValue(output, receiver);
			case CallClosure(value, closure, arguments):
				begin(output, "CallClosure", 3);
				writeValue(output, value);
				writeValue(output, closure);
				writeValues(output, arguments);
			case ToVirtual(outputValue, value):
				writeTwoValues(output, "ToVirtual", outputValue, value);
			case MethodCall(value, object, name, arguments):
				begin(output, "MethodCall", 4);
				writeValue(output, value);
				writeValue(output, object);
				writeText(output, name);
				writeValues(output, arguments);
			case NewObject(value, name):
				begin(output, "NewObject", 2);
				writeValue(output, value);
				writeText(output, name);
			case FieldGet(value, object, name):
				begin(output, "FieldGet", 3);
				writeValue(output, value);
				writeValue(output, object);
				writeText(output, name);
			case FieldSet(object, name, value):
				begin(output, "FieldSet", 3);
				writeValue(output, object);
				writeText(output, name);
				writeValue(output, value);
			case ArrayGet(value, array, index):
				writeThreeValues(output, "ArrayGet", value, array, index);
			case ArraySet(array, index, value):
				writeThreeValues(output, "ArraySet", array, index, value);
			case ArraySize(value, array):
				writeTwoValues(output, "ArraySize", value, array);
			case MakeEnum(value, name, constructor, arguments):
				begin(output, "MakeEnum", 4);
				writeValue(output, value);
				writeText(output, name);
				writeInt(output, constructor);
				writeValues(output, arguments);
			case EnumIndex(outputValue, value):
				writeTwoValues(output, "EnumIndex", outputValue, value);
			case EnumField(outputValue, value, constructor, field):
				begin(output, "EnumField", 4);
				writeValue(output, outputValue);
				writeValue(output, value);
				writeInt(output, constructor);
				writeInt(output, field);
		}
	}

	public static function read(input:BytesInput, totalLength:Int, values:Map<Int, IrValue>):IrInstruction {
		var name = readString(input, totalLength);
		if (!CONSTRUCTORS.exists(name))
			throw "Unknown IR instruction";
		var count = input.readInt32();
		function arity(expected:Int):Void
			if (count != expected)
				throw "Invalid IR instruction operand count";
		return switch name {
			case "Phi":
				arity(2);
				Phi(readValue(input, values), readPhiInputs(input, values));
			case "ConstVoid":
				arity(1);
				ConstVoid(readValue(input, values));
			case "ConstInt":
				arity(2);
				ConstInt(readValue(input, values), readInt(input));
			case "ConstFloat":
				arity(2);
				ConstFloat(readValue(input, values), readFloat(input));
			case "ConstString":
				arity(2);
				ConstString(readValue(input, values), readText(input, totalLength));
			case "ConstBool":
				arity(2);
				ConstBool(readValue(input, values), readBool(input));
			case "ConstNull":
				arity(1);
				ConstNull(readValue(input, values));
			case "TypeValue":
				arity(2);
				TypeValue(readValue(input, values), readType(input, totalLength));
			case "ToDyn":
				arity(2);
				ToDyn(readValue(input, values), readValue(input, values));
			case "IntToFloat":
				arity(2);
				IntToFloat(readValue(input, values), readValue(input, values));
			case "IntToInt64":
				arity(2);
				IntToInt64(readValue(input, values), readValue(input, values));
			case "FloatToInt":
				arity(2);
				FloatToInt(readValue(input, values), readValue(input, values));
			case "SafeCast":
				arity(2);
				SafeCast(readValue(input, values), readValue(input, values));
			case "BeginTry":
				arity(2);
				BeginTry(readInt(input), readInt(input));
			case "EndTry":
				arity(1);
				EndTry(readInt(input));
			case "Catch":
				arity(1);
				Catch(readValue(input, values));
			case "GlobalGet":
				arity(2);
				GlobalGet(readValue(input, values), readText(input, totalLength));
			case "GlobalSet":
				arity(2);
				GlobalSet(readText(input, totalLength), readValue(input, values));
			case "Add":
				arity(3);
				Add(readValue(input, values), readValue(input, values), readValue(input, values));
			case "Sub":
				arity(3);
				Sub(readValue(input, values), readValue(input, values), readValue(input, values));
			case "Mul":
				arity(3);
				Mul(readValue(input, values), readValue(input, values), readValue(input, values));
			case "Div":
				arity(3);
				Div(readValue(input, values), readValue(input, values), readValue(input, values));
			case "Mod":
				arity(3);
				Mod(readValue(input, values), readValue(input, values), readValue(input, values));
			case "BitAnd":
				arity(3);
				BitAnd(readValue(input, values), readValue(input, values), readValue(input, values));
			case "BitXor":
				arity(3);
				BitXor(readValue(input, values), readValue(input, values), readValue(input, values));
			case "BitOr":
				arity(3);
				BitOr(readValue(input, values), readValue(input, values), readValue(input, values));
			case "ShiftLeft":
				arity(3);
				ShiftLeft(readValue(input, values), readValue(input, values), readValue(input, values));
			case "ShiftRight":
				arity(3);
				ShiftRight(readValue(input, values), readValue(input, values), readValue(input, values));
			case "UnsignedShiftRight":
				arity(3);
				UnsignedShiftRight(readValue(input, values), readValue(input, values), readValue(input, values));
			case "Less":
				arity(3);
				Less(readValue(input, values), readValue(input, values), readValue(input, values));
			case "LessEqual":
				arity(3);
				LessEqual(readValue(input, values), readValue(input, values), readValue(input, values));
			case "Equal":
				arity(3);
				Equal(readValue(input, values), readValue(input, values), readValue(input, values));
			case "Call":
				arity(3);
				Call(readValue(input, values), readText(input, totalLength), readValues(input, values));
			case "CNativeCall":
				arity(3);
				CNativeCall(readValue(input, values), readText(input, totalLength), readValues(input, values));
			case "StaticClosure":
				arity(2);
				StaticClosure(readValue(input, values), readText(input, totalLength));
			case "InstanceClosure":
				arity(3);
				InstanceClosure(readValue(input, values), readText(input, totalLength), readValue(input, values));
			case "CallClosure":
				arity(3);
				CallClosure(readValue(input, values), readValue(input, values), readValues(input, values));
			case "ToVirtual":
				arity(2);
				ToVirtual(readValue(input, values), readValue(input, values));
			case "MethodCall":
				arity(4);
				MethodCall(readValue(input, values), readValue(input, values), readText(input, totalLength), readValues(input, values));
			case "NewObject":
				arity(2);
				NewObject(readValue(input, values), readText(input, totalLength));
			case "FieldGet":
				arity(3);
				FieldGet(readValue(input, values), readValue(input, values), readText(input, totalLength));
			case "FieldSet":
				arity(3);
				FieldSet(readValue(input, values), readText(input, totalLength), readValue(input, values));
			case "ArrayGet":
				arity(3);
				ArrayGet(readValue(input, values), readValue(input, values), readValue(input, values));
			case "ArraySet":
				arity(3);
				ArraySet(readValue(input, values), readValue(input, values), readValue(input, values));
			case "ArraySize":
				arity(2);
				ArraySize(readValue(input, values), readValue(input, values));
			case "MakeEnum":
				arity(4);
				MakeEnum(readValue(input, values), readText(input, totalLength), readInt(input), readValues(input, values));
			case "EnumIndex":
				arity(2);
				EnumIndex(readValue(input, values), readValue(input, values));
			case "EnumField":
				arity(4);
				EnumField(readValue(input, values), readValue(input, values), readInt(input), readInt(input));
			default: throw "Unknown IR instruction";
		};
	}

	static function expectTag(input:BytesInput, expected:Int):Void
		if (input.readByte() != expected)
			throw "Invalid IR instruction operand tag";

	static function readValue(input:BytesInput, values:Map<Int, IrValue>):IrValue {
		expectTag(input, 0);
		return IrValueTableCodec.readReference(input, values);
	}

	static function readInt(input:BytesInput):Int {
		expectTag(input, 1);
		return input.readInt32();
	}

	static function readFloat(input:BytesInput):Float {
		expectTag(input, 2);
		return input.readDouble();
	}

	static function readBool(input:BytesInput):Bool {
		expectTag(input, 3);
		var value = input.readByte();
		if (value != 0 && value != 1)
			throw "Invalid IR boolean operand";
		return value == 1;
	}

	static function readText(input:BytesInput, total:Int):String {
		expectTag(input, 4);
		return readString(input, total);
	}

	static function readValues(input:BytesInput, values:Map<Int, IrValue>):Array<IrValue> {
		expectTag(input, 5);
		var count = input.readInt32();
		if (count < 0 || count > 0x100000)
			throw "Invalid IR operand array";
		return [for (_ in 0...count) readValue(input, values)];
	}

	static function readType(input:BytesInput, total:Int):IrType {
		expectTag(input, 6);
		return IrTypeCodec.readType(input, total, 0);
	}

	static function readPhiInputs(input:BytesInput, values:Map<Int, IrValue>):Array<compiler.ir.Ir.IrPhiInput> {
		expectTag(input, 5);
		var count = input.readInt32();
		if (count < 0 || count > 0x100000)
			throw "Invalid IR operand array";
		var result = [];
		for (_ in 0...count) {
			expectTag(input, 7);
			var block = input.readInt32();
			if (block < 0)
				throw "Invalid IR block reference";
			result.push({block: block, value: IrValueTableCodec.readReference(input, values)});
		}
		return result;
	}

	static function begin(output:BytesOutput, name:String, count:Int):Void {
		writeString(output, name);
		output.writeInt32(count);
	}

	static function writeValue(output:BytesOutput, value:IrValue):Void {
		output.writeByte(0);
		IrValueTableCodec.writeReference(output, value);
	}

	static function writeInt(output:BytesOutput, value:Int):Void {
		output.writeByte(1);
		output.writeInt32(value);
	}

	static function writeFloat(output:BytesOutput, value:Float):Void {
		output.writeByte(2);
		output.writeDouble(value);
	}

	static function writeBool(output:BytesOutput, value:Bool):Void {
		output.writeByte(3);
		output.writeByte(value ? 1 : 0);
	}

	static function writeText(output:BytesOutput, value:String):Void {
		output.writeByte(4);
		writeString(output, value);
	}

	static function writeType(output:BytesOutput, value:IrType):Void {
		output.writeByte(6);
		IrTypeCodec.writeType(output, value, 0);
	}

	static function writeValues(output:BytesOutput, values:Array<IrValue>):Void {
		if (values.length > 0x100000)
			throw "Invalid IR operand array";
		output.writeByte(5);
		output.writeInt32(values.length);
		for (value in values)
			writeValue(output, value);
	}

	static function writePhiInputs(output:BytesOutput, inputs:Array<compiler.ir.Ir.IrPhiInput>):Void {
		if (inputs.length > 0x100000)
			throw "Invalid IR operand array";
		output.writeByte(5);
		output.writeInt32(inputs.length);
		for (input in inputs) {
			output.writeByte(7);
			output.writeInt32(input.block);
			IrValueTableCodec.writeReference(output, input.value);
		}
	}

	static function writeTwoValues(output:BytesOutput, name:String, first:IrValue, second:IrValue):Void {
		begin(output, name, 2);
		writeValue(output, first);
		writeValue(output, second);
	}

	static function writeThreeValues(output:BytesOutput, name:String, first:IrValue, second:IrValue, third:IrValue):Void {
		begin(output, name, 3);
		writeValue(output, first);
		writeValue(output, second);
		writeValue(output, third);
	}

	static function readOperand(input:BytesInput, totalLength:Int, values:Map<Int, IrValue>):Dynamic
		return switch input.readByte() {
			case 0: IrValueTableCodec.readReference(input, values);
			case 1: input.readInt32();
			case 2: input.readDouble();
			case 3:
				var value = input.readByte();
				if (value != 0 && value != 1)
					throw "Invalid IR boolean operand";
				value == 1;
			case 4: readString(input, totalLength);
			case 5:
				var count = input.readInt32();
				if (count < 0 || count > 0x100000)
					throw "Invalid IR operand array";
				[for (_ in 0...count) readOperand(input, totalLength, values)];
			case 6: IrTypeCodec.readType(input, totalLength, 0);
			case 7: {block: input.readInt32(), value: IrValueTableCodec.readReference(input, values)};
			default: throw "Invalid IR instruction operand tag";
		};

	static function writeString(output:BytesOutput, value:String):Void {
		var bytes = HaxeBytes.ofString(value);
		if (bytes.length > 0x100000)
			throw "Invalid IR instruction string";
		output.writeInt32(bytes.length);
		output.write(bytes);
	}

	static function readString(input:BytesInput, totalLength:Int):String {
		var length = input.readInt32();
		if (length < 0 || length > 0x100000 || length > totalLength - input.position)
			throw "Invalid IR instruction string";
		return input.readString(length);
	}
}
