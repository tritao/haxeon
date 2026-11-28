package std.bytes;

import std.bytes.Encoding;

@:hlNative("haxeon_runtime", "__bytes_sub")
internal extern function copyRange(bytes:Bytes, pos:Int, len:Int):Bytes;

@:hlNative("haxeon_runtime", "__bytes_get_string")
internal extern function decodeRange(bytes:Bytes, pos:Int, len:Int):String;

/**
 * The Bytes methods that check a range, written in Haxe once for every target: `sub`, `getString`, and the throw of the
 * writers the runtime checks. The compiler maps each method to its function here (`PlatformAbi`) and loads this module with
 * `std.bytes.Bytes`, as almost every use of Bytes calls one.
 */
function sub(bytes:Bytes, pos:Int, len:Int):Bytes {
	// `len > length - pos` rather than `pos + len > length`, which overflows for a large len.
	if (pos < 0 || len < 0 || len > bytes.length - pos)
		outsideBounds();
	return copyRange(bytes, pos, len);
}

/**
 * The string `len` bytes at `pos` encode in `encoding`: UTF-8 by default, or UTF-16 code units, little-endian, up to the
 * first zero unit (an odd last byte is a unit's low byte).
 */
function getString(bytes:Bytes, pos:Int, len:Int, encoding:Encoding = Utf8):String {
	if (pos < 0 || len < 0 || len > bytes.length - pos)
		outsideBounds();
	if (encoding == Utf8)
		return decodeRange(bytes, pos, len);
	// Transcoded to UTF-8, which every target decodes the same way; a unit takes at most three bytes, a pair four.
	var utf8 = Bytes.alloc(((len + 1) >> 1) * 3), size = 0, index = 0;
	while (index < len) {
		var code = codeUnit(bytes, pos, len, index);
		if (code == 0)
			break;
		index += 2;
		var low = index < len ? codeUnit(bytes, pos, len, index) : 0;
		if (code >= 0xD800 && code < 0xDC00 && low >= 0xDC00 && low < 0xE000) {
			code = ((code - 0xD800) << 10) + (low - 0xDC00) + 0x10000;
			index += 2;
		}
		if (code < 0x80)
			utf8.set(size++, code);
		else if (code < 0x800) {
			utf8.set(size++, 0xC0 | (code >> 6));
			utf8.set(size++, 0x80 | (code & 0x3F));
		} else if (code < 0x10000) {
			utf8.set(size++, 0xE0 | (code >> 12));
			utf8.set(size++, 0x80 | ((code >> 6) & 0x3F));
			utf8.set(size++, 0x80 | (code & 0x3F));
		} else {
			utf8.set(size++, 0xF0 | (code >> 18));
			utf8.set(size++, 0x80 | ((code >> 12) & 0x3F));
			utf8.set(size++, 0x80 | ((code >> 6) & 0x3F));
			utf8.set(size++, 0x80 | (code & 0x3F));
		}
	}
	return decodeRange(utf8, 0, size);
}

internal function codeUnit(bytes:Bytes, pos:Int, len:Int, index:Int):Int
	return bytes.get(pos + index) | (index + 1 < len ? bytes.get(pos + index + 1) << 8 : 0);

/**
 * What a method throws for a position or range outside the bytes, a misuse: the writers the runtime checks (`set`,
 * `setInt32`, `setFloat`, `setDouble`, `blit`) and the methods here.
 */
function outsideBounds():Void
	throw new haxe.Exception("std.bytes.Bytes: the position or range is outside the bytes");
