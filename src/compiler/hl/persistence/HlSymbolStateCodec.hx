package compiler.hl.persistence;

import compiler.hl.incremental.HlSymbolTable;
import compiler.hl.incremental.HlSymbolTable.HlNamedIndex;
import compiler.hl.incremental.HlSymbolTable.HlNamedSlots;
import compiler.hl.incremental.HlSymbolTable.HlSymbolState;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

/** Deterministic binary persistence for all HashLink symbol-table state. */
class HlSymbolStateCodec {
	static inline final MAX_ITEMS = 0x100000;
	static inline final MAX_BYTES = 0x1000000;

	public static function encode(state:HlSymbolState):Bytes {
		var out = new BytesOutput();
		out.bigEndian = false;
		out.writeString("HSS");
		out.writeByte(1);
		writeInts(out, state.ints);
		writeStrings(out, state.strings);
		writeFloats(out, state.floats);
		writeBytes(out, HlTypeDefStateCodec.encode(state.types));
		writeInts(out, state.globals);
		writeMap(out, state.typeIndices);
		writeMap(out, state.globalIndices);
		writeMap(out, state.objectIndices);
		writeNested(out, state.objectMethodIndices);
		writeNested(out, state.interfaceMethodIndices);
		return out.getBytes();
	}

	public static function decode(bytes:Bytes):HlSymbolState {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != "HSS" || input.readByte() != 1)
				throw "Invalid HashLink symbol state";
			var ints = readInts(input),
				strings = readStrings(input, bytes.length),
				floats = readFloats(input),
				typeBytes = readBytes(input, bytes.length),
				globals = readInts(input),
				types = HlTypeDefStateCodec.decode(typeBytes, strings.length, globals.length),
				typeIndices = readMap(input, bytes.length),
				globalIndices = readMap(input, bytes.length),
				objectIndices = readMap(input, bytes.length),
				objectMethods = readNested(input, bytes.length),
				interfaceMethods = readNested(input, bytes.length);
			if (input.position != bytes.length)
				throw "Trailing HashLink symbol state data";
			validateRange(typeIndices, types.length, "type");
			validateRange(globalIndices, globals.length, "global");
			validateRange(objectIndices, types.length, "object");
			return {
				ints: ints,
				strings: strings,
				floats: floats,
				types: types,
				globals: globals,
				typeIndices: typeIndices,
				globalIndices: globalIndices,
				objectIndices: objectIndices,
				objectMethodIndices: objectMethods,
				interfaceMethodIndices: interfaceMethods
			};
		} catch (error:haxe.io.Eof)
			throw "Truncated HashLink symbol state";
	}

	public static function restore(bytes:Bytes):HlSymbolTable
		return HlSymbolTable.fromState(decode(bytes));

	static function writeInts(out:BytesOutput, values:Array<Int>):Void {
		writeCount(out, values.length);
		for (value in values)
			out.writeInt32(value);
	}

	static function readInts(input:BytesInput):Array<Int>
		return [for (_ in 0...readCount(input)) input.readInt32()];

	static function writeFloats(out:BytesOutput, values:Array<Float>):Void {
		writeCount(out, values.length);
		for (value in values)
			out.writeDouble(value);
	}

	static function readFloats(input:BytesInput):Array<Float>
		return [for (_ in 0...readCount(input)) input.readDouble()];

	static function writeStrings(out:BytesOutput, values:Array<String>):Void {
		writeCount(out, values.length);
		for (value in values)
			writeString(out, value);
	}

	static function readStrings(input:BytesInput, total:Int):Array<String>
		return [for (_ in 0...readCount(input)) readString(input, total)];

	static function writeMap(out:BytesOutput, values:Array<HlNamedIndex>):Void {
		writeCount(out, values.length);
		for (entry in values) {
			writeString(out, entry.name);
			out.writeInt32(entry.index);
		}
	}

	static function readMap(input:BytesInput, total:Int):Array<HlNamedIndex> {
		var result = [], seen:Map<String, Bool> = [];
		for (_ in 0...readCount(input)) {
			var name = readString(input, total), index = input.readInt32();
			if (name.length == 0 || index < 0 || seen.exists(name))
				throw "Invalid HashLink named index";
			seen.set(name, true);
			result.push({name: name, index: index});
		}
		return result;
	}

	static function writeNested(out:BytesOutput, values:Array<HlNamedSlots>):Void {
		writeCount(out, values.length);
		for (entry in values) {
			writeString(out, entry.name);
			writeMap(out, entry.slots);
		}
	}

	static function readNested(input:BytesInput, total:Int):Array<HlNamedSlots> {
		var result = [], seen:Map<String, Bool> = [];
		for (_ in 0...readCount(input)) {
			var name = readString(input, total);
			if (name.length == 0 || seen.exists(name))
				throw "Invalid HashLink slot owner";
			seen.set(name, true);
			result.push({name: name, slots: readMap(input, total)});
		}
		return result;
	}

	static function validateRange(values:Array<HlNamedIndex>, limit:Int, kind:String):Void
		for (entry in values)
			if (entry.index >= limit)
				throw 'Invalid HashLink $kind index';

	static function writeBytes(out:BytesOutput, bytes:Bytes):Void {
		if (bytes.length > MAX_BYTES)
			throw "HashLink symbol section is too large";
		out.writeInt32(bytes.length);
		out.write(bytes);
	}

	static function readBytes(input:BytesInput, total:Int):Bytes {
		var length = input.readInt32();
		if (length < 0 || length > MAX_BYTES || length > total - input.position)
			throw "Invalid HashLink symbol section";
		return input.read(length);
	}

	static function writeString(out:BytesOutput, value:String):Void {
		var bytes = Bytes.ofString(value);
		writeBytes(out, bytes);
	}

	static function readString(input:BytesInput, total:Int):String
		return readBytes(input, total).toString();

	static function writeCount(out:BytesOutput, count:Int):Void {
		if (count < 0 || count > MAX_ITEMS)
			throw "Too many HashLink symbols";
		out.writeInt32(count);
	}

	static function readCount(input:BytesInput):Int {
		var count = input.readInt32();
		if (count < 0 || count > MAX_ITEMS)
			throw "Invalid HashLink symbol count";
		return count;
	}
}
