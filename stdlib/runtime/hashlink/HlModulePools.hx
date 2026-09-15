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
	public final stringCount:Int;
	public final bytes:RawPtr<UInt8>;
	public final byteCount:Int;
	public final bytePositions:RawPtr<Int32>;
	public final bytePositionCount:Int;
	public final entryPoint:Int;

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
		stringCount = stringValues.length;
		strings = stringCount == 0 ? RawPtr.nullPtr() : arena.allocNativePointerArray(stringCount);
		stringLengths = stringCount == 0 ? RawPtr.nullPtr() : arena.allocInt32Array(stringCount);
		for (index in 0...stringCount) {
			strings.offset(index).store(builder.utf8Name(stringValues[index]));
			stringLengths.offset(index).store(cast HlTypeBuilder.utf8Length(stringValues[index]));
		}
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
		if (index < 0 || index >= stringCount)
			throw 'HashLink module string index $index is outside 0...$stringCount';
		return strings.offset(index).load();
	}
}
