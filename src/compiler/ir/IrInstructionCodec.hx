package compiler.ir;

import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.ir.Ir.BlockId;
import haxe.io.Bytes as HaxeBytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

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
		"Less" => true,
		"LessEqual" => true,
		"Equal" => true,
		"Call" => true,
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
		} catch (error:Dynamic) {
			if (Std.isOfType(error, String) && StringTools.startsWith(cast error, "Invalid IR") || error == "Unknown IR instruction")
				throw error;
			throw "Invalid IR instruction operands";
		}
	}

	public static function write(output:BytesOutput, instruction:IrInstruction):Void {
		var name = Type.enumConstructor(instruction);
		if (!CONSTRUCTORS.exists(name))
			throw "Unknown IR instruction";
		writeString(output, name);
		var parameters = Type.enumParameters(instruction);
		output.writeInt32(parameters.length);
		for (parameter in parameters)
			writeOperand(output, parameter);
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
			case "SafeCast":
				arity(2);
				SafeCast(readValue(input, values), readValue(input, values));
			case "BeginTry":
				arity(2);
				BeginTry(readInt(input), readInt(input));
			case "EndTry":
				arity(0);
				EndTry;
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
			result.push({block: (block : BlockId), value: IrValueTableCodec.readReference(input, values)});
		}
		return result;
	}

	static function writeOperand(output:BytesOutput, value:Dynamic):Void {
		var valueType = Type.typeof(value);
		if (valueType.match(TClass(IrValue))) {
			output.writeByte(0);
			IrValueTableCodec.writeReference(output, cast value);
		} else if (valueType.match(TInt)) {
			output.writeByte(1);
			output.writeInt32(value);
		} else if (valueType.match(TFloat)) {
			output.writeByte(2);
			output.writeDouble(value);
		} else if (valueType.match(TBool)) {
			output.writeByte(3);
			output.writeByte(value ? 1 : 0);
		} else if (valueType.match(TClass(String))) {
			output.writeByte(4);
			writeString(output, value);
		} else if (value is Array) {
			var values:Array<Dynamic> = cast value;
			if (values.length > 0x100000)
				throw "Invalid IR operand array";
			output.writeByte(5);
			output.writeInt32(values.length);
			for (item in values)
				writeOperand(output, item);
		} else if (valueType.match(TEnum(IrType))) {
			output.writeByte(6);
			IrTypeCodec.writeType(output, cast value, 0);
		} else if (value != null && Reflect.hasField(value, "block") && Reflect.hasField(value, "value")) {
			output.writeByte(7);
			output.writeInt32(Reflect.field(value, "block"));
			IrValueTableCodec.writeReference(output, Reflect.field(value, "value"));
		} else
			throw "Invalid IR instruction operand";
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
