package std.bytes;

import std.bytes.BytesBounds.outsideBounds;

/**
 * Bytes methods written in Haxe once for every target: `fill`, the 16-bit and the Int64 accessors. A write outside the bytes
 * throws; a read there answers 0, as the runtime's own reads (`get`, `getInt32`, ...) do.
 * The compiler maps each method to its function here (`PlatformAbi`) and loads this module only where a program calls one, as it
 * does `BytesHex`.
 */
function fill(bytes:Bytes, pos:Int, len:Int, value:Int):Void {
	// `len > length - pos` rather than `pos + len > length`, which overflows for a large len.
	if (pos < 0 || len < 0 || len > bytes.length - pos)
		outsideBounds();
	for (index in pos...pos + len)
		bytes.set(index, value);
}

internal function getUInt16(bytes:Bytes, pos:Int):Int
	return pos < 0 || pos > bytes.length - 2 ? 0 : bytes.get(pos) | (bytes.get(pos + 1) << 8);

internal function setUInt16(bytes:Bytes, pos:Int, value:Int):Void {
	if (pos < 0 || pos > bytes.length - 2)
		outsideBounds();
	bytes.set(pos, value);
	bytes.set(pos + 1, value >> 8);
}

internal function getInt64(bytes:Bytes, pos:Int):haxe.Int64
	return pos < 0 || pos > bytes.length - 8 ? haxe.Int64.ofInt(0) : haxe.Int64.make(bytes.getInt32(pos + 4),
		bytes.getInt32(pos));

internal function setInt64(bytes:Bytes, pos:Int, value:haxe.Int64):Void {
	if (pos < 0 || pos > bytes.length - 8)
		outsideBounds();
	bytes.setInt32(pos + 4, value.high);
	bytes.setInt32(pos, value.low);
}
