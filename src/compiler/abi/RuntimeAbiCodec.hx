package compiler.abi;

import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

/** Strict deterministic persistence for the compiler's published runtime ABI. */
class RuntimeAbiCodec {
	static inline final MAGIC = "ABI";
	static inline final VERSION = 1;
	static inline final MAX_ENTRIES = 0x100000;
	static inline final MAX_STRING_BYTES = 0x1000000;

	public static function encode(descriptor:RuntimeAbiDescriptor):Bytes {
		var output = new BytesOutput();
		output.bigEndian = false;
		output.writeString(MAGIC);
		output.writeByte(VERSION);
		writeMap(output, descriptor.functions);
		writeMap(output, descriptor.objects);
		writeMap(output, descriptor.interfaces);
		writeMap(output, descriptor.enums);
		writeMap(output, descriptor.globals);
		return output.getBytes();
	}

	public static function decode(bytes:Bytes):RuntimeAbiDescriptor {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != MAGIC)
				throw "Invalid runtime ABI state";
			if (input.readByte() != VERSION)
				throw "Unsupported runtime ABI state version";
			var functions = readMap(input, bytes.length),
				objects = readMap(input, bytes.length),
				interfaces = readMap(input, bytes.length),
				enums = readMap(input, bytes.length),
				globals = readMap(input, bytes.length);
			if (input.position != bytes.length)
				throw "Trailing runtime ABI state data";
			return {
				functions: functions,
				objects: objects,
				interfaces: interfaces,
				enums: enums,
				globals: globals
			};
		} catch (error:haxe.io.Eof) {
			throw "Truncated runtime ABI state";
		}
	}

	static function writeMap(output:BytesOutput, values:Map<String, String>):Void {
		var names = [for (name in values.keys()) name];
		names.sort(Reflect.compare);
		output.writeInt32(names.length);
		for (name in names) {
			writeString(output, name);
			writeString(output, values.get(name));
		}
	}

	static function readMap(input:BytesInput, totalLength:Int):Map<String, String> {
		var count = input.readInt32(), result:Map<String, String> = [];
		if (count < 0 || count > MAX_ENTRIES)
			throw "Invalid runtime ABI entry count";
		for (_ in 0...count) {
			var name = readString(input, totalLength),
				value = readString(input, totalLength);
			if (result.exists(name))
				throw "Duplicate runtime ABI name";
			result.set(name, value);
		}
		return result;
	}

	static function writeString(output:BytesOutput, value:String):Void {
		var bytes = Bytes.ofString(value);
		output.writeInt32(bytes.length);
		output.write(bytes);
	}

	static function readString(input:BytesInput, totalLength:Int):String {
		var length = input.readInt32();
		if (length < 0 || length > MAX_STRING_BYTES || length > totalLength - input.position)
			throw "Invalid runtime ABI string";
		return input.readString(length);
	}
}
