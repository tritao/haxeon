package haxe.io;

/**
 * Haxe's Bytes: the same type as `std.bytes.Bytes`, so a value passes between Haxe's API and std's as it is
 * (stdlib/UPSTREAM.md lists where it behaves otherwise than Haxe's).
 */
typedef Bytes = std.bytes.Bytes;

/** Haxe's `Bytes.ofString`: UTF-8 by default, and with `RawNative` UTF-16 code units, little-endian. */
function ofString(s:String, ?encoding:Encoding):Bytes
	return std.bytes.Bytes.ofString(s, encoding == RawNative ? Utf16 : Utf8);

/** Haxe's `Bytes.ofHex`. */
function ofHex(s:String):Bytes
	return std.bytes.Bytes.ofHex(s);
