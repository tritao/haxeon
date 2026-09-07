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
@:hlNative("realtime_runtime", "__string_starts_with")
extern function stringToolsStartsWith(s:String, start:String):Bool;

@:hlNative("realtime_runtime", "__string_ends_with")
extern function stringToolsEndsWith(s:String, end:String):Bool;

@:hlNative("realtime_runtime", "__string_replace")
extern function stringToolsReplace(s:String, sub:String, by:String):String;

@:hlNative("realtime_runtime", "__string_ltrim")
extern function stringToolsLtrim(s:String):String;

@:hlNative("realtime_runtime", "__string_trim")
extern function stringToolsTrim(s:String):String;

@:hlNative("realtime_runtime", "__string_is_space")
extern function stringToolsIsSpace(s:String, pos:Int):Bool;

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

	public static inline function trim(s:String):String {
		return stringToolsTrim(s);
	}

	public static inline function isSpace(s:String, pos:Int):Bool {
		return stringToolsIsSpace(s, pos);
	}
}
