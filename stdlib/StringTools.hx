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
@:hlNative("haxeon_runtime", "__string_starts_with")
extern function stringToolsStartsWith(s:String, start:String):Bool;

@:hlNative("haxeon_runtime", "__string_ends_with")
extern function stringToolsEndsWith(s:String, end:String):Bool;

#if !wasm
@:hlNative("haxeon_runtime", "__string_replace")
extern function stringToolsReplace(s:String, sub:String, by:String):String;

@:hlNative("haxeon_runtime", "__string_ltrim")
extern function stringToolsLtrim(s:String):String;

@:hlNative("haxeon_runtime", "__string_trim")
extern function stringToolsTrim(s:String):String;

@:hlNative("haxeon_runtime", "__string_is_space")
extern function stringToolsIsSpace(s:String, pos:Int):Bool;
#else
// Wasm implements these in Haxe with the HashLink runtime's semantics.
function stringToolsReplace(s:String, sub:String, by:String):String
	return sub.length == 0 ? s.split("").join(by) : s.split(sub).join(by);

function stringToolsLtrim(s:String):String {
	var start = 0;
	while (start < s.length && s.charCodeAt(start) <= 32)
		start++;
	return s.substring(start);
}

function stringToolsTrim(s:String):String {
	var start = 0, end = s.length;
	while (start < end && s.charCodeAt(start) <= 32)
		start++;
	while (end > start && s.charCodeAt(end - 1) <= 32)
		end--;
	return s.substring(start, end);
}

function stringToolsIsSpace(s:String, pos:Int):Bool {
	if (pos < 0 || pos >= s.length)
		return false;
	var code = s.charCodeAt(pos);
	return (code > 8 && code < 14) || code == 32;
}
#end

/** Common string helpers backed by the stable runtime ABI where necessary. */
class StringTools {
	public static inline function contains(s:String, value:String):Bool {
		return s.indexOf(value) != -1;
	}

	public static inline function startsWith(s:String, start:String):Bool {
		return stringToolsStartsWith(s, start);
	}

	public static inline function endsWith(s:String, end:String):Bool {
		return stringToolsEndsWith(s, end);
	}

	public static inline function replace(s:String, sub:String, by:String):String {
		return stringToolsReplace(s, sub, by);
	}

	public static inline function ltrim(s:String):String {
		return stringToolsLtrim(s);
	}

	public static function rtrim(s:String):String {
		var length = s.length;
		var removed = 0;
		while (removed < length && isSpace(s, length - removed - 1))
			removed++;
		return removed == 0 ? s : s.substr(0, length - removed);
	}

	public static inline function trim(s:String):String {
		return stringToolsTrim(s);
	}

	public static function lpad(s:String, c:String, length:Int):String {
		if (c.length == 0)
			return s;
		var buffer = new StringBuf();
		var padding = length - s.length;
		while (buffer.length < padding)
			buffer.add(c);
		buffer.add(s);
		return buffer.toString();
	}

	public static function rpad(s:String, c:String, length:Int):String {
		if (c.length == 0)
			return s;
		var buffer = new StringBuf();
		buffer.add(s);
		while (buffer.length < length)
			buffer.add(c);
		return buffer.toString();
	}

	public static function hex(n:Int, ?digits:Int):String {
		var result = "";
		var characters = "0123456789ABCDEF";
		do {
			result = characters.charAt(n & 15) + result;
			n = n >>> 4;
		} while (n > 0);
		if (digits != null)
			while (result.length < digits)
				result = "0" + result;
		return result;
	}

	public static inline function isSpace(s:String, pos:Int):Bool {
		return stringToolsIsSpace(s, pos);
	}
}
