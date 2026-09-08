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
@:hlNative("haxeon_runtime", "__std_parse_int")
extern function stdParseInt(value:String):Int;

@:hlNative("haxeon_runtime", "__std_parse_float")
extern function stdParseFloat(value:String):Float;

@:hlNative("haxeon_runtime", "__std_int_f64")
extern function stdIntFloat(value:Float):Int;

@:hlNative("haxeon_runtime", "__std_random")
extern function stdRandom(limit:Int):Int;

@:hlNative("haxeon_runtime", "__std_string")
extern function stdString(value:Dynamic):String;

/** Supported core conversions backed by the stable runtime ABI. */
class Std {
	public static inline function string(value:Dynamic):String {
		return stdString(value);
	}

	public static inline function int(value:Float):Int {
		return stdIntFloat(value);
	}

	public static inline function parseInt(value:String):Int {
		return stdParseInt(value);
	}

	public static inline function parseFloat(value:String):Float {
		return stdParseFloat(value);
	}

	public static inline function random(limit:Int):Int {
		return stdRandom(limit);
	}

	/** Runtime type test lowered intrinsically by the Haxeon compiler. */
	public static function isOfType(value:Dynamic, type:Dynamic):Bool {
		return false;
	}
}
