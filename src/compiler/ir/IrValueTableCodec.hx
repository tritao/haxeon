package compiler.ir;

import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import haxe.io.Bytes as HaxeBytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

/** Canonical value table used by persisted IR functions. */
class IrValueTableCodec {
	public static inline final MAX_VALUES = 0x100000;

	public static function encode(values:Array<IrValue>):HaxeBytes {
		var output = new BytesOutput();
		output.bigEndian = false;
		output.writeString("IRV");
		output.writeByte(1);
		write(output, values);
		return output.getBytes();
	}

	public static function decode(bytes:HaxeBytes):Array<IrValue> {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != "IRV")
				throw "Invalid IR value table";
			if (input.readByte() != 1)
				throw "Unsupported IR value table version";
			var result = read(input, bytes.length);
			if (input.position != bytes.length)
				throw "Trailing IR value table data";
			return result;
		} catch (error:haxe.io.Eof) {
			throw "Truncated IR value table";
		}
	}

	public static function write(output:BytesOutput, values:Array<IrValue>):Void {
		if (values.length > MAX_VALUES)
			throw "Too many IR values";
		var ordered = values.copy();
		ordered.sort(function(a, b) return (a.id : Int) - (b.id : Int));
		output.writeInt32(ordered.length);
		var previous = -1;
		for (value in ordered) {
			var id:Int = value.id;
			if (id < 0 || id <= previous)
				throw "Duplicate or invalid IR value ID";
			previous = id;
			output.writeInt32(id);
			writeString(output, value.name);
			IrTypeCodec.writeType(output, value.type, 0);
		}
	}

	public static function read(input:BytesInput, totalLength:Int):Array<IrValue> {
		var count = input.readInt32();
		if (count < 0 || count > MAX_VALUES)
			throw "Invalid IR value count";
		var result:Array<IrValue> = [], seen:Map<Int, Bool> = [];
		for (_ in 0...count) {
			var id = input.readInt32();
			if (id < 0 || seen.exists(id))
				throw "Duplicate or invalid IR value ID";
			seen.set(id, true);
			result.push(new IrValue(id, readString(input, totalLength), IrTypeCodec.readType(input, totalLength, 0)));
		}
		return result;
	}

	public static function byId(values:Array<IrValue>):Map<Int, IrValue> {
		var result:Map<Int, IrValue> = [];
		for (value in values) {
			var id:Int = value.id;
			if (result.exists(id))
				throw "Duplicate IR value ID";
			result.set(id, value);
		}
		return result;
	}

	public static function writeReference(output:BytesOutput, value:IrValue):Void
		output.writeInt32(value.id);

	public static function readReference(input:BytesInput, values:Map<Int, IrValue>):IrValue {
		var id = input.readInt32(), value = values.get(id);
		if (id < 0 || value == null)
			throw "Unknown IR value reference";
		return value;
	}

	static function writeString(output:BytesOutput, value:String):Void {
		var bytes = HaxeBytes.ofString(value);
		if (bytes.length > 0x100000)
			throw "IR value name is too long";
		output.writeInt32(bytes.length);
		output.write(bytes);
	}

	static function readString(input:BytesInput, totalLength:Int):String {
		var length = input.readInt32();
		if (length < 0 || length > 0x100000 || length > totalLength - input.position)
			throw "Invalid IR value name";
		return input.readString(length);
	}
}
