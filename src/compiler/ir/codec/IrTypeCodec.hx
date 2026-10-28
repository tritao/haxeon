package compiler.ir.codec;

import compiler.ir.Ir.IrType;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

/** Deterministic, strictly validated persistence for IR types. */
class IrTypeCodec {
	static inline final VERSION = 6;
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
			var version = input.readByte();
			if (version < 1 || version > VERSION)
				throw "Unsupported IR type state version";
			var result = readType(input, bytes.length, 0);
			if (input.position != bytes.length)
				throw "Trailing IR type state data";
			return result;
		} catch (error:haxe.io.Eof) {
			throw "Truncated IR type state";
		}
	}

	/**
	 * Writes `type`. With `erase`, names are written without their lambda ordinals (`IrFunctionStateCodec.codeFingerprint`):
	 * a lambda's environment and the lambdas written in it are named after it, so without this a lambda that only moved among
	 * its siblings would look like different code.
	 */
	public static function writeType(output:BytesOutput, type:IrType, depth:Int, erase:Bool = false):Void {
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
			case ManagedBytes:
				output.writeByte(14);
			case Dyn:
				output.writeByte(5);
			case TypeRef:
				output.writeByte(6);
			case Array(element):
				output.writeByte(7);
				writeType(output, element, depth + 1, erase);
			case Iterator(element):
				output.writeByte(15);
				writeType(output, element, depth + 1, erase);
			case Enum(name):
				writeNamed(output, 8, name, erase);
			case Obj(name):
				writeNamed(output, 9, name, erase);
			case Abstract(name):
				writeNamed(output, 10, name, erase);
			case Virtual(name):
				writeNamed(output, 11, name, erase);
			case Function(arguments, result):
				if (arguments.length > MAX_ARGUMENTS)
					throw "Too many IR function type arguments";
				output.writeByte(12);
				output.writeInt32(arguments.length);
				for (argument in arguments)
					writeType(output, argument, depth + 1, erase);
				writeType(output, result, depth + 1, erase);
			case I64:
				output.writeByte(13);
			case RawPtr:
				output.writeByte(16);
			case F32:
				output.writeByte(17);
			case Nullable(element):
				output.writeByte(18);
				writeType(output, element, depth + 1, erase);
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
			case 14: ManagedBytes;
			case 15: Iterator(readType(input, totalLength, depth + 1));
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
			case 13: I64;
			case 16: RawPtr;
			case 17: F32;
			case 18: Nullable(readType(input, totalLength, depth + 1));
			default: throw "Unknown IR type tag";
		};
	}

	static function writeNamed(output:BytesOutput, tag:Int, name:String, erase:Bool):Void {
		if (name.length == 0)
			throw "IR named type cannot be empty";
		output.writeByte(tag);
		writeString(output, erase ? withoutOrdinals(name) : name);
	}

	/**
	 * `name` with every lambda ordinal (`#<digits>` ending a name or a step of one, see `LambdaName`) reduced to `#`.
	 * Haxe identifiers cannot contain `#`, so only the compiler's own separators are touched. It also takes text that names
	 * types, like a signature (`(Obj($lambda-env:...#0),I32)->I32`), where a name can end at `)`, `,` or `>`.
	 */
	public static function withoutOrdinals(name:String):String {
		if (name.indexOf("#") < 0)
			return name;
		var result = new StringBuf(), index = 0;
		while (index < name.length) {
			var code = name.charCodeAt(index);
			result.addChar(code);
			index++;
			if (code != "#".code)
				continue;
			var end = index;
			while (end < name.length && name.charCodeAt(end) >= "0".code && name.charCodeAt(end) <= "9".code)
				end++;
			if (end > index && (end == name.length || endsStep(name.charCodeAt(end))))
				index = end;
		}
		return result.toString();
	}

	static function endsStep(code:Int):Bool
		return code == ":".code || code == ")".code || code == ",".code || code == ">".code;

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
