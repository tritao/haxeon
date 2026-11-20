package haxe.io;

/**
 * Bytes methods written in Haxe once for every target, with Haxe's HashLink bounds: `fill`, the 16-bit and the Int64 accessors.
 * The compiler maps each method to its function here (`PlatformAbi`) and loads this module only where a program calls one, as it
 * does `BytesHex`.
 */
function fill(bytes:Bytes, pos:Int, len:Int, value:Int):Void {
	// `len > length - pos` rather than `pos + len > length`, which overflows for a large len.
	if (pos < 0 || len < 0 || len > bytes.length - pos)
		throw Error.OutsideBounds;
	for (index in pos...pos + len)
		bytes.set(index, value);
}

function getUInt16(bytes:Bytes, pos:Int):Int
	return pos < 0 || pos > bytes.length - 2 ? 0 : bytes.get(pos) | (bytes.get(pos + 1) << 8);

function setUInt16(bytes:Bytes, pos:Int, value:Int):Void {
	if (pos < 0 || pos > bytes.length - 2)
		throw Error.OutsideBounds;
	bytes.set(pos, value);
	bytes.set(pos + 1, value >> 8);
}

function getInt64(bytes:Bytes, pos:Int):haxe.Int64
	return pos < 0 || pos > bytes.length - 8 ? haxe.Int64.ofInt(0) : haxe.Int64.make(bytes.getInt32(pos + 4),
		bytes.getInt32(pos));

function setInt64(bytes:Bytes, pos:Int, value:haxe.Int64):Void {
	if (pos < 0 || pos > bytes.length - 8)
		throw Error.OutsideBounds;
	bytes.setInt32(pos + 4, value.high);
	bytes.setInt32(pos, value.low);
}
