package compiler.ir;

import compiler.ir.Ir.IrType;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

/** Deterministic, strictly validated persistence for IR types. */
class IrTypeCodec {
	static inline final VERSION = 1;
	static inline final MAX_DEPTH = 64;
	static inline final MAX_ARGUMENTS = 0x10000;
	static inline final MAX_STRING_BYTES = 0x100000;

	public static function encode(type:IrType):haxe.io.Bytes {
		var output = new BytesOutput();
		output.bigEndian = false;
		output.writeString("IRT");
		output.writeByte(VERSION);
		writeType(output, type, 0);
		return output.getBytes();
	}

	public static function decode(bytes:haxe.io.Bytes):IrType {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != "IRT")
				throw "Invalid IR type state";
			if (input.readByte() != VERSION)
				throw "Unsupported IR type state version";
			var result = readType(input, bytes.length, 0);
			if (input.position != bytes.length)
				throw "Trailing IR type state data";
			return result;
		} catch (error:haxe.io.Eof) {
			throw "Truncated IR type state";
		}
	}

	public static function writeType(output:BytesOutput, type:IrType, depth:Int):Void {
		if (depth >= MAX_DEPTH)
			throw "IR type nesting limit exceeded";
		switch type {
			case Void:
				output.writeByte(0);
			case I32:
				output.writeByte(1);
			case Bool:
				output.writeByte(2);
			case F64:
				output.writeByte(3);
			case Bytes:
				output.writeByte(4);
			case Dyn:
				output.writeByte(5);
			case TypeRef:
				output.writeByte(6);
			case Array(element):
				output.writeByte(7);
				writeType(output, element, depth + 1);
			case Enum(name):
				writeNamed(output, 8, name);
			case Obj(name):
				writeNamed(output, 9, name);
			case Abstract(name):
				writeNamed(output, 10, name);
			case Virtual(name):
				writeNamed(output, 11, name);
			case Function(arguments, result):
				if (arguments.length > MAX_ARGUMENTS)
					throw "Too many IR function type arguments";
				output.writeByte(12);
				output.writeInt32(arguments.length);
				for (argument in arguments)
					writeType(output, argument, depth + 1);
				writeType(output, result, depth + 1);
		}
	}

	public static function readType(input:BytesInput, totalLength:Int, depth:Int):IrType {
		if (depth >= MAX_DEPTH)
			throw "IR type nesting limit exceeded";
		return switch input.readByte() {
			case 0: Void;
			case 1: I32;
			case 2: Bool;
			case 3: F64;
			case 4: Bytes;
			case 5: Dyn;
			case 6: TypeRef;
			case 7: Array(readType(input, totalLength, depth + 1));
			case 8: Enum(readString(input, totalLength));
			case 9: Obj(readString(input, totalLength));
			case 10: Abstract(readString(input, totalLength));
			case 11: Virtual(readString(input, totalLength));
			case 12:
				var count = input.readInt32();
				if (count < 0 || count > MAX_ARGUMENTS)
					throw "Invalid IR function type argument count";
				Function([for (_ in 0...count) readType(input, totalLength, depth + 1)], readType(input, totalLength, depth + 1));
			default: throw "Unknown IR type tag";
		};
	}

	static function writeNamed(output:BytesOutput, tag:Int, name:String):Void {
		if (name.length == 0)
			throw "IR named type cannot be empty";
		output.writeByte(tag);
		writeString(output, name);
	}

	public static function writeString(output:BytesOutput, value:String):Void {
		var bytes = haxe.io.Bytes.ofString(value);
		if (bytes.length > MAX_STRING_BYTES)
			throw "IR state string is too long";
		output.writeInt32(bytes.length);
		output.write(bytes);
	}

	public static function readString(input:BytesInput, totalLength:Int):String {
		var length = input.readInt32();
		if (length < 0 || length > MAX_STRING_BYTES || length > totalLength - input.position)
			throw "Invalid IR state string";
		var value = input.readString(length);
		if (value.length == 0)
			throw "IR state string cannot be empty";
		return value;
	}
}
