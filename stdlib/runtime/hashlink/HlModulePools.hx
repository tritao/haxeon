package runtime.hashlink;

import haxe.io.Bytes;
import runtime.memory.RawPtr;

/** Arena-owned scalar pools that form the non-type portion of an HLB module. */
class HlModulePools {
	public final arena:HlTypeArena;
	public final ints:RawPtr<Int32>;
	public final intCount:Int;
	public final floats:RawPtr<Float>;
	public final floatCount:Int;
	public final strings:RawPtr<RawPtr<UInt8>>;
	public final stringLengths:RawPtr<Int32>;
	public final ustrings:RawPtr<RawPtr<UInt16>>;
	public final stringCount:Int;
	public final bytes:RawPtr<UInt8>;
	public final byteCount:Int;
	public final bytePositions:RawPtr<Int32>;
	public final bytePositionCount:Int;
	public final entryPoint:Int;
	public final stringTable:HlStringTable;

	public function new(arena:HlTypeArena, builder:HlTypeBuilder, intValues:Array<Int>, floatValues:Array<Float>, stringValues:Array<String>,
		byteValues:Bytes, bytePositionValues:Array<Int>, entryPoint:Int) {
		if (arena == null || builder == null || intValues == null || floatValues == null || stringValues == null || byteValues == null || bytePositionValues == null)
			throw "HashLink module pools require initialized source tables";
		this.arena = arena;
		intCount = intValues.length;
			ints = intCount == 0 ? RawPtr.nullPtr() : arena.allocInt32Array(intCount);
		for (index in 0...intCount)
			ints.offset(index).store(cast intValues[index]);
		floatCount = floatValues.length;
		floats = floatCount == 0 ? RawPtr.nullPtr() : arena.allocFloat64Array(floatCount);
		for (index in 0...floatCount)
			floats.offset(index).store(floatValues[index]);
		stringTable = new HlStringTable(arena, stringValues);
		stringCount = stringTable.count;
		strings = stringTable.pointers;
		stringLengths = stringTable.lengths;
		ustrings = stringTable.ustrings;
		byteCount = byteValues.length;
		bytes = byteCount == 0 ? RawPtr.nullPtr() : arena.allocUInt8Array(byteCount);
		for (index in 0...byteCount)
			bytes.offset(index).store(cast byteValues.get(index));
		bytePositionCount = bytePositionValues.length;
		bytePositions = bytePositionCount == 0 ? RawPtr.nullPtr() : arena.allocInt32Array(bytePositionCount);
		for (index in 0...bytePositionCount)
			bytePositions.offset(index).store(cast bytePositionValues[index]);
		this.entryPoint = entryPoint;
	}

	/** Return one arena-owned UTF-8 string pointer from the module string pool. */
	public function string(index:Int):RawPtr<UInt8> {
		return stringTable.pointer(index);
	}

	public inline function stringLength(index:Int):Int
		return stringTable.lengthAt(index);

	/** Validate scalar-pool storage and all byte-position references. */
	public function validate():Int {
		if (intCount < 0 || floatCount < 0 || stringCount < 0 || byteCount < 0 || bytePositionCount < 0 || entryPoint < 0)
			throw "HashLink module pools contain invalid counts";
		if ((intCount > 0 && ints.isNull()) || (floatCount > 0 && floats.isNull())
			|| (stringCount > 0 && (strings.isNull() || stringLengths.isNull()))
			|| (byteCount > 0 && bytes.isNull()) || (bytePositionCount > 0 && bytePositions.isNull()))
			throw "HashLink module pools contain incomplete storage";
		for (index in 0...stringCount) {
			var string = strings.offset(index).load(), length:Int = cast stringLengths.offset(index).load();
			if (string.isNull() || length < 0)
				throw "HashLink module string pool contains invalid storage";
		}
		for (index in 0...bytePositionCount) {
			var position:Int = cast bytePositions.offset(index).load();
			if (position < 0 || position >= byteCount)
				throw "HashLink byte position is outside the byte pool";
		}
		return stringCount;
	}
}
