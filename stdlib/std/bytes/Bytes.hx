package std.bytes;

import std.bytes.Encoding;

@:hlNative("haxeon_runtime", "__bytes_of_string")
internal extern function utf8Bytes(value:String):Bytes;

/** The bytes of `text` in `encoding`: UTF-8 by default, or UTF-16 code units, little-endian. */
function ofString(text:String, encoding:Encoding = Utf8):Bytes {
	if (encoding == Utf8)
		return utf8Bytes(text);
	var bytes = Bytes.alloc(text.length << 1);
	for (index in 0...text.length) {
		var unit = (text.charCodeAt(index):Int);
		bytes.set(index << 1, unit);
		bytes.set((index << 1) + 1, unit >> 8);
	}
	return bytes;
}

/** The bytes a string of hexadecimal digits spells, two digits a byte, in either case; throws for any other text. */
function ofHex(text:String):Bytes {
	if ((text.length & 1) != 0)
		throw new haxe.Exception('std.bytes.Bytes.ofHex: "$text" has an odd number of digits');
	var bytes = Bytes.alloc(text.length >> 1);
	for (index in 0...bytes.length) {
		var high = digit(text, index * 2), low = digit(text, index * 2 + 1);
		bytes.set(index, (high << 4) | low);
	}
	return bytes;
}

internal function digit(text:String, at:Int):Int {
	var code = (text.charCodeAt(at):Int);
	if (code >= "0".code && code <= "9".code)
		return code - "0".code;
	if (code >= "a".code && code <= "f".code)
		return code - "a".code + 10;
	if (code >= "A".code && code <= "F".code)
		return code - "A".code + 10;
	throw new haxe.Exception('std.bytes.Bytes.ofHex: "$text" is not hexadecimal at $at');
}

/**
 * A fixed-length sequence of bytes, read and written in place: `get`/`set` a byte, `getInt32`, `getUInt16`, `getInt64`,
 * `getFloat`, `getDouble` and their setters (little-endian), `blit`, `fill`, `sub`, `compare`, `getString` and `toHex`.
 * A write, `sub` or `getString` outside the bytes is a misuse, and throws; a read of a number there answers 0.
 * `alloc`, `ofString` and `ofHex` make one.
 */
extern class Bytes {
	/** `length` new bytes, all zero. */
	@:hlNative("haxeon_runtime", "__bytes_alloc")
	public static function alloc(length:Int):Bytes;

	/** A view of `length` bytes of `bytes` from `offset`, which shares them rather than copying. */
	@:hlNative("haxeon_runtime", "__bytes_view")
	public static function view(bytes:Bytes, offset:Int, length:Int):Bytes;
}
