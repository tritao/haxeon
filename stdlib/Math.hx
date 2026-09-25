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
@:pure @:hlNative("haxeon_runtime", "__math_is_nan")
extern function mathIsNaN(value:Float):Bool;

@:pure @:hlNative("haxeon_runtime", "__math_is_finite")
extern function mathIsFinite(value:Float):Bool;

@:pure @:hlNative("haxeon_runtime", "__math_pow")
extern function mathPow(value:Float, exponent:Float):Float;

@:pure @:hlNative("haxeon_runtime", "__math_cos")
extern function mathCos(value:Float):Float;

@:pure @:hlNative("haxeon_runtime", "__math_sin")
extern function mathSin(value:Float):Float;

@:pure @:hlNative("haxeon_runtime", "__math_tan")
extern function mathTan(value:Float):Float;

@:pure @:hlNative("haxeon_runtime", "__math_sqrt")
extern function mathSqrt(value:Float):Float;

@:pure @:hlNative("haxeon_runtime", "__math_atan2")
extern function mathAtan2(y:Float, x:Float):Float;

@:pure @:hlNative("haxeon_runtime", "__math_round")
extern function mathRound(value:Float):Int;

@:pure @:hlNative("haxeon_runtime", "__math_ceil")
extern function mathCeil(value:Float):Int;

@:pure @:hlNative("haxeon_runtime", "__math_floor")
extern function mathFloor(value:Float):Int;

/** Supported mathematical helpers backed by the stable runtime ABI. */
@:pure
class Math {
	public static inline var PI:Float = 3.141592653589793;

	public static inline function min(left:Float, right:Float):Float
		return left < right ? left : right;

	public static inline function max(left:Float, right:Float):Float
		return left > right ? left : right;

	public static inline function abs(value:Float):Float
		return value < 0 ? -value : value;

	public static inline function isNaN(value:Float):Bool
		return mathIsNaN(value);

	public static inline function isFinite(value:Float):Bool
		return mathIsFinite(value);

	public static inline function pow(value:Float, exponent:Float):Float
		return mathPow(value, exponent);

	public static inline function cos(value:Float):Float
		return mathCos(value);

	public static inline function sin(value:Float):Float
		return mathSin(value);

	public static inline function tan(value:Float):Float
		return mathTan(value);

	public static inline function sqrt(value:Float):Float
		return mathSqrt(value);

	public static inline function atan2(y:Float, x:Float):Float
		return mathAtan2(y, x);

	public static inline function acos(value:Float):Float
		return mathAtan2(mathSqrt(1.0 - value * value), value);

	public static inline function round(value:Float):Int
		return mathRound(value);

	public static inline function ceil(value:Float):Int
		return mathCeil(value);

	public static inline function floor(value:Float):Int
		return mathFloor(value);

	/** Largest integral Float not above `value`; NaN, infinities, and values from 2^52 are already integral. */
	public static function ffloor(value:Float):Float {
		if (!(Math.abs(value) < 4503599627370496.0))
			return value;
		var truncated = value - value % 1.0;
		return truncated > value ? truncated - 1.0 : truncated;
	}

	/** Smallest integral Float not below `value`. */
	public static function fceil(value:Float):Float {
		if (!(Math.abs(value) < 4503599627370496.0))
			return value;
		var truncated = value - value % 1.0;
		return truncated < value ? truncated + 1.0 : truncated;
	}

	/** Nearest integral Float, with halves rounded up like `round`. */
	public static function fround(value:Float):Float {
		if (!(Math.abs(value) < 4503599627370496.0))
			return value;
		var lower = ffloor(value);
		return value - lower >= 0.5 ? lower + 1.0 : lower;
	}
}
