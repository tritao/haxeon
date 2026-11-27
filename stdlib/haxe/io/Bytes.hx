/*
 * Copyright (C)2005-2019 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 * IN THE SOFTWARE.
 */

package haxe.io;

@:hlNative("haxeon_runtime", "__bytes_of_string")
internal extern function utf8Bytes(value:String):Bytes;

/**
 * The bytes of `s` in `encoding`, as Haxe's `Bytes.ofString` on HashLink: UTF-8 by default, and with `RawNative` the string's
 * UTF-16 code units, little-endian. A module function of haxe.io.Bytes, so it is called as `Bytes.ofString(s)`, beside the natives
 * the extern class binds.
 */
function ofString(s:String, ?encoding:Encoding):Bytes {
	if (encoding != RawNative)
		return utf8Bytes(s);
	var bytes = Bytes.alloc(s.length << 1);
	for (index in 0...s.length) {
		var unit = (s.charCodeAt(index):Int);
		bytes.set(index << 1, unit);
		bytes.set((index << 1) + 1, unit >> 8);
	}
	return bytes;
}

/** The bytes a string of hexadecimal digits spells, as Haxe's `Bytes.ofHex`: a digit is read by its low bits, unchecked. */
function ofHex(s:String):Bytes {
	var length = s.length;
	if ((length & 1) != 0)
		throw "Not a hex string (odd number of digits)";
	var bytes = Bytes.alloc(length >> 1);
	for (index in 0...bytes.length) {
		var high = (s.charCodeAt(index * 2):Int), low = (s.charCodeAt(index * 2 + 1):Int);
		high = (high & 0xF) + ((high & 0x40) >> 6) * 9;
		low = (low & 0xF) + ((low & 0x40) >> 6) * 9;
		bytes.set(index, ((high << 4) | low) & 0xFF);
	}
	return bytes;
}

/** A fixed-length sequence of bytes, read and written in place. `ofString`, `ofHex` and `alloc` make one. */
extern class Bytes {
	/** `length` new bytes, all zero. */
	@:hlNative("haxeon_runtime", "__bytes_alloc")
	public static function alloc(length:Int):Bytes;

	/** Returns a zero-copy view over a validated byte range. */
	@:hlNative("haxeon_runtime", "__bytes_view")
	public static function view(bytes:Bytes, offset:Int, length:Int):Bytes;
}
