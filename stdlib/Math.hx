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
internal extern function mathIsNaN(value:Float):Bool;

@:pure @:hlNative("haxeon_runtime", "__math_is_finite")
internal extern function mathIsFinite(value:Float):Bool;

@:pure @:hlNative("haxeon_runtime", "__math_pow")
internal extern function mathPow(value:Float, exponent:Float):Float;

@:pure @:hlNative("haxeon_runtime", "__math_cos")
internal extern function mathCos(value:Float):Float;

@:pure @:hlNative("haxeon_runtime", "__math_sin")
internal extern function mathSin(value:Float):Float;

@:pure @:hlNative("haxeon_runtime", "__math_tan")
internal extern function mathTan(value:Float):Float;

@:pure @:hlNative("haxeon_runtime", "__math_sqrt")
internal extern function mathSqrt(value:Float):Float;

@:pure @:hlNative("haxeon_runtime", "__math_abs")
internal extern function mathAbs(value:Float):Float;

@:pure @:hlNative("haxeon_runtime", "__math_min")
internal extern function mathMin(left:Float, right:Float):Float;

@:pure @:hlNative("haxeon_runtime", "__math_max")
internal extern function mathMax(left:Float, right:Float):Float;

@:pure @:hlNative("haxeon_runtime", "__math_atan2")
internal extern function mathAtan2(y:Float, x:Float):Float;

@:pure @:hlNative("haxeon_runtime", "__math_exp")
internal extern function mathExp(value:Float):Float;

@:pure @:hlNative("haxeon_runtime", "__math_log")
internal extern function mathLog(value:Float):Float;

@:pure @:hlNative("haxeon_runtime", "__math_round")
internal extern function mathRound(value:Float):Int;

@:pure @:hlNative("haxeon_runtime", "__math_ceil")
internal extern function mathCeil(value:Float):Int;

@:pure @:hlNative("haxeon_runtime", "__math_floor")
internal extern function mathFloor(value:Float):Int;

/** Mathematical constants and functions on `Float`, in radians where an angle is meant. */
class Math {
	/** Pseudo-random value in [0, 1), using the existing portable integer RNG. */
	public static inline function random():Float
		return (Std.random(4096) * 4096.0 + Std.random(4096)) / 16777216.0;

	/** The ratio of a circle's circumference to its diameter, π. */
	public static inline var PI:Float = 3.141592653589793;

	/** IEEE 754 positive infinity, as in the standard Haxe `Math`. */
	public static inline var POSITIVE_INFINITY:Float = 1.0 / 0.0;

	/** IEEE 754 negative infinity, as in the standard Haxe `Math`. */
	public static inline var NEGATIVE_INFINITY:Float = -1.0 / 0.0;

	/** IEEE 754 quiet NaN, as in the standard Haxe `Math`. */
	public static inline var NaN:Float = 0.0 / 0.0;

	// NaN in either operand gives NaN, and -0.0 is below 0.0. Wasm has an instruction for each; elsewhere the
	// comparisons are inlined, which is cheaper than a native call.
	#if wasm
	/** The smaller of `left` and `right`: NaN when either is NaN, and -0.0 below 0.0. */
	@:pure public static inline function min(left:Float, right:Float):Float
		return mathMin(left, right);

	/** The larger of `left` and `right`: NaN when either is NaN, and 0.0 above -0.0. */
	@:pure public static inline function max(left:Float, right:Float):Float
		return mathMax(left, right);
	#else
	/** The smaller of `left` and `right`: NaN when either is NaN, and -0.0 below 0.0. */
	@:pure public static inline function min(left:Float, right:Float):Float
		return left != left || right != right
			? Math.NaN : (left < right ? left : (right < left ? right : (1 / left < 0 ? left : right)));

	/** The larger of `left` and `right`: NaN when either is NaN, and 0.0 above -0.0. */
	@:pure public static inline function max(left:Float, right:Float):Float
		return left != left || right != right
			? Math.NaN : (left > right ? left : (right > left ? right : (1 / left < 0 ? right : left)));
	#end

	/** The absolute value of `value`. */
	@:pure public static inline function abs(value:Float):Float
		return mathAbs(value);

	/** Whether `value` is NaN, the one value not equal to itself. */
	@:pure public static inline function isNaN(value:Float):Bool
		return mathIsNaN(value);

	/** Whether `value` is neither infinite nor NaN. */
	@:pure public static inline function isFinite(value:Float):Bool
		return mathIsFinite(value);

	/** `value` raised to `exponent`. */
	@:pure public static inline function pow(value:Float, exponent:Float):Float
		return mathPow(value, exponent);

	/** The cosine of the angle `value`, in radians. */
	@:pure public static inline function cos(value:Float):Float
		return mathCos(value);

	/** The sine of the angle `value`, in radians. */
	@:pure public static inline function sin(value:Float):Float
		return mathSin(value);

	/** The tangent of the angle `value`, in radians. */
	@:pure public static inline function tan(value:Float):Float
		return mathTan(value);

	/** The square root of `value`: NaN below zero. */
	@:pure public static inline function sqrt(value:Float):Float
		return mathSqrt(value);

	/** The angle, in radians from -π to π, from the positive x axis to the point (`x`, `y`). */
	@:pure public static inline function atan2(y:Float, x:Float):Float
		return mathAtan2(y, x);

	/** The angle, in radians from 0 to π, whose cosine is `value`: NaN outside -1 to 1. */
	@:pure public static inline function acos(value:Float):Float
		return mathAtan2(mathSqrt(1.0 - value * value), value);

	/** The angle, in radians from -π/2 to π/2, whose sine is `value`: NaN outside -1 to 1. */
	@:pure public static inline function asin(value:Float):Float
		return mathAtan2(value, mathSqrt(1.0 - value * value));

	/** The angle, in radians from -π/2 to π/2, whose tangent is `value`. */
	@:pure public static inline function atan(value:Float):Float
		return mathAtan2(value, 1.0);

	/** e raised to `value`. */
	@:pure public static inline function exp(value:Float):Float
		return mathExp(value);

	/** Natural logarithm: NaN below zero, negative infinity at zero. */
	@:pure public static inline function log(value:Float):Float
		return mathLog(value);

	/**
	 * `value` rounded to the nearest `Int`, halves up (-1.5 gives -1). A value outside the `Int` range gives an
	 * unspecified result: `fround` keeps it a `Float`.
	 */
	@:pure public static inline function round(value:Float):Int
		return mathRound(value);

	/**
	 * The smallest `Int` not below `value`. A value outside the `Int` range gives an unspecified result: `fceil` keeps
	 * it a `Float`.
	 */
	@:pure public static inline function ceil(value:Float):Int
		return mathCeil(value);

	/**
	 * The largest `Int` not above `value`. A value outside the `Int` range gives an unspecified result: `ffloor` keeps
	 * it a `Float`.
	 */
	@:pure public static inline function floor(value:Float):Int
		return mathFloor(value);

	/** Largest integral Float not above `value`; NaN, infinities, and values from 2^52 are already integral. */
	@:pure public static function ffloor(value:Float):Float {
		if (value == 0.0 || !(Math.abs(value) < 4503599627370496.0))
			return value;
		var truncated = value - value % 1.0;
		return truncated > value ? truncated - 1.0 : truncated;
	}

	/** Smallest integral Float not below `value`. */
	@:pure public static function fceil(value:Float):Float {
		if (value == 0.0 || !(Math.abs(value) < 4503599627370496.0))
			return value;
		var truncated = value - value % 1.0;
		return truncated < value ? truncated + 1.0 : truncated;
	}

	/** Nearest integral Float, with halves rounded up like `round`. */
	@:pure public static function fround(value:Float):Float {
		if (!(Math.abs(value) < 4503599627370496.0))
			return value;
		var lower = ffloor(value);
		return value - lower >= 0.5 ? lower + 1.0 : lower;
	}
}
