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
@:hlNative("haxeon_runtime", "__math_is_nan")
extern function mathIsNaN(value:Float):Bool;

@:hlNative("haxeon_runtime", "__math_is_finite")
extern function mathIsFinite(value:Float):Bool;

@:hlNative("realtime_runtime", "__math_pow")
extern function mathPow(value:Float, exponent:Float):Float;

/** Supported mathematical helpers backed by the stable runtime ABI. */
class Math {
	public static inline function min(left:Float, right:Float):Float
		return left < right ? left : right;

	public static inline function max(left:Float, right:Float):Float
		return left > right ? left : right;

	public static inline function isNaN(value:Float):Bool
		return mathIsNaN(value);

	public static inline function isFinite(value:Float):Bool
		return mathIsFinite(value);

	public static inline function pow(value:Float, exponent:Float):Float
		return mathPow(value, exponent);
}
