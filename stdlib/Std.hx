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

#if wasm
import runtime.Ryu;
#end

#if !wasm
@:hlNative("haxeon_runtime", "__std_parse_float")
internal extern function stdParseFloat(value:String):Float;
#else
// Wasm parses floats in Haxe with the HashLink runtime's C semantics (strtod).
function stdParseFloat(value:String):Float {
	if (value == null)
		return Math.NaN;
	var position = skipSpace(value, 0), negative = false;
	if (position < value.length && (value.charCodeAt(position) == "+".code || value.charCodeAt(position) == "-".code))
		negative = value.charCodeAt(position++) == "-".code;
	var rest = value.substr(position).toLowerCase();
	if (StringTools.startsWith(rest, "inf"))
		return negative ? Math.NEGATIVE_INFINITY : Math.POSITIVE_INFINITY;
	if (StringTools.startsWith(rest, "nan"))
		return Math.NaN;
	// Up to 19 significant decimal digits accumulate exactly enough for Clinger's fast path.
	var mantissa = 0.0, significant = 0, exponent = 0, digits = 0;
	while (position < value.length && digitValue(value.charCodeAt(position)) < 10) {
		var digit = digitValue(value.charCodeAt(position++));
		digits++;
		if (significant < 19) {
			mantissa = mantissa * 10 + digit;
			if (mantissa > 0)
				significant++;
		} else
			exponent++;
	}
	if (position < value.length && value.charCodeAt(position) == ".".code) {
		position++;
		while (position < value.length && digitValue(value.charCodeAt(position)) < 10) {
			var digit = digitValue(value.charCodeAt(position++));
			digits++;
			if (significant < 19) {
				mantissa = mantissa * 10 + digit;
				exponent--;
				if (mantissa > 0)
					significant++;
			}
		}
	}
	if (digits == 0)
		return Math.NaN;
	if (position < value.length && (value.charCodeAt(position) == "e".code || value.charCodeAt(position) == "E".code)) {
		var cursor = position + 1, exponentNegative = false, exponentValue = 0, exponentDigits = 0;
		if (cursor < value.length && (value.charCodeAt(cursor) == "+".code || value.charCodeAt(cursor) == "-".code))
			exponentNegative = value.charCodeAt(cursor++) == "-".code;
		while (cursor < value.length && digitValue(value.charCodeAt(cursor)) < 10) {
			if (exponentValue < 100000)
				exponentValue = exponentValue * 10 + digitValue(value.charCodeAt(cursor));
			cursor++;
			exponentDigits++;
		}
		if (exponentDigits > 0)
			exponent += exponentNegative ? -exponentValue : exponentValue;
	}
	var result = scaleByPowerOfTen(mantissa, exponent);
	return negative ? -result : result;
}

/** Exact for |exponent| <= 22 with an exactly representable mantissa, as in Clinger's fast path. */
function scaleByPowerOfTen(mantissa:Float, exponent:Int):Float {
	if (mantissa == 0)
		return 0;
	var magnitude = exponent < 0 ? -exponent : exponent, power = 1.0, base = 10.0;
	if (magnitude > 400)
		return exponent < 0 ? 0.0 : Math.POSITIVE_INFINITY;
	if (exponent < 0 && magnitude > 22) {
		// Divide in two steps so tiny results do not underflow before the mantissa applies.
		mantissa /= 1e22;
		magnitude -= 22;
	}
	while (magnitude > 0) {
		if ((magnitude & 1) != 0)
			power *= base;
		base *= base;
		magnitude = magnitude >> 1;
	}
	return exponent < 0 ? mantissa / power : mantissa * power;
}

#end

/**
 * Haxe's Std.parseInt on every target: leading whitespace, an optional sign, then "0x" and hexadecimal digits or decimal
 * digits, up to the first character that is not one; null when there are no digits. A leading 0 does not make it octal.
 */
function stdParseInt(value:Null<String>):Null<Int> {
	if (value == null)
		return null;
	var position = skipSpace(value, 0), negative = false;
	if (position < value.length && (value.charCodeAt(position) == "+".code || value.charCodeAt(position) == "-".code))
		negative = value.charCodeAt(position++) == "-".code;
	var base = 10;
	if (position + 2 < value.length && value.charCodeAt(position) == "0".code
		&& (value.charCodeAt(position + 1) == "x".code || value.charCodeAt(position + 1) == "X".code)
		&& digitValue(value.charCodeAt(position + 2)) < 16) {
		base = 16;
		position += 2;
	}
	var start = position, result = 0;
	while (position < value.length) {
		var digit = digitValue(value.charCodeAt(position));
		if (digit >= base)
			break;
		result = result * base + digit;
		position++;
	}
	if (position == start)
		return null;
	return negative ? -result : result;
}

internal function skipSpace(value:String, position:Int):Int {
	while (position < value.length) {
		var code = value.charCodeAt(position);
		if (code != 32 && (code < 9 || code > 13))
			break;
		position++;
	}
	return position;
}

internal function digitValue(code:Int):Int
	return code >= "0".code && code <= "9".code ? code - "0".code : code >= "a".code
		&& code <= "z".code ? code - "a".code + 10 : code >= "A".code
		&& code <= "Z".code ? code - "A".code + 10 : 99;


@:hlNative("haxeon_runtime", "__std_int_f64")
internal extern function stdIntFloat(value:Float):Int;

#if !wasm
@:hlNative("haxeon_runtime", "__std_random")
internal extern function stdRandom(limit:Int):Int;
#else
/**
 * Wasm draws from a xorshift32 generator with a fixed seed, so every session sees the same sequence. HashLink seeds its
 * generator from the time and the process id, as Haxe does; seeding here needs a host clock that every Wasm compile has,
 * and HaxeonHost is only registered for full Wasm builds. It is not suitable for anything secret.
 */
function stdRandom(limit:Int):Int {
	if (limit <= 0)
		return 0;
	var state = RandomState.state;
	state ^= state << 13;
	state ^= state >>> 17;
	state ^= state << 5;
	RandomState.state = state;
	// Drop the sign bit so the remainder is never negative.
	return (state >>> 1) % limit;
}

private class RandomState {
	public static var state = 0x2545F491;
}
#end

@:hlNative("haxeon_runtime", "__std_string")
internal extern function stdString(value:Dynamic):String;

/** Conversions between values and strings, numbers, and types, and the random generator. */
class Std {
	/**
	 * `value` as a string: a string itself, `"null"` for null, a number as Haxe prints it, an object through its
	 * `toString` when it has one.
	 */
	public static inline function string(value:Dynamic):String {
		#if wasm
		if (Std.isOfType(value, Float))
			return Ryu.format(cast value);
		if (Std.isOfType(value, Array))
			return arrayString(cast value);
		#end
		return stdString(value);
	}

	/** `map` as `Map.toString` prints it, `[key => value, ...]`, or `"null"`. */
	public static function stringifyMap<K, V>(map:Null<Map<K, V>>):String
		return map == null ? "null" : formatMapEntries(map.keys(), map.iterator());

	/** Read both projections before formatting, since an entry's toString can mutate the map. */
	public static function formatMapEntries<K, V>(keys:Iterator<K>, values:Iterator<V>):String {
		var output = new StringBuf();
		output.add("[");
		var first = true;
		while (keys.hasNext()) {
			if (!first)
				output.add(", ");
			first = false;
			var key = Std.string(keys.next());
			output.add(key == null ? "null" : key);
			output.add(" => ");
			var value = Std.string(values.next());
			output.add(value == null ? "null" : value);
		}
		output.add("]");
		return output.toString();
	}

	#if wasm
	/** Arrays print as Haxe's Array.toString does, and as HashLink does here: `[a,b]`. */
	static function arrayString(values:Array<Dynamic>):String {
		var output = new StringBuf();
		output.add("[");
		for (index in 0...values.length) {
			if (index > 0)
				output.add(",");
			output.add(Std.string(values[index]));
		}
		output.add("]");
		return output.toString();
	}
	#end

	/**
	 * `value` truncated toward zero to an `Int`. A value outside the `Int` range, or NaN, gives an unspecified result.
	 */
	public static inline function int(value:Float):Int {
		return stdIntFloat(value);
	}

	/** The integer `value` starts with, as Haxe's: null when it does not start with one. */
	public static inline function parseInt(value:String):Null<Int> {
		return stdParseInt(value);
	}

	/**
	 * The number `value` starts with, after leading whitespace, as `strtod` reads it (`"2.5px"` gives 2.5), or NaN when
	 * it does not start with one.
	 */
	public static inline function parseFloat(value:String):Float {
		return stdParseFloat(value);
	}

	/**
	 * A pseudo-random `Int` from 0 to `limit - 1`, or 0 when `limit` is not positive. The generator is seeded from the
	 * time and the process when first used; it is not for cryptography.
	 */
	public static inline function random(limit:Int):Int {
		return stdRandom(limit);
	}

	/** Runtime type test lowered intrinsically by the Haxeon compiler. */
	public static function isOfType(value:Dynamic, type:Dynamic):Bool {
		return false;
	}

	/** The value as the requested class or interface when it is an instance of it, else null; lowered by the compiler. */
	public static function downcast(value:Dynamic, type:Dynamic):Dynamic {
		return null;
	}

	/** True only when the runtime class is exactly the requested class. */
	public static function isExactType(value:Dynamic, type:Dynamic):Bool {
		return false;
	}
}
