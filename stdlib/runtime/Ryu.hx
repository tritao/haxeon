package runtime;

import runtime.FloatBits;
import runtime.RyuTables;
import runtime.RuntimeData;

/** A finite Ryū decimal, or one of the special IEEE-754 values. */
typedef RyuDecimal = {
	var significand:haxe.Int64;
	var exponent:Int;
	var kind:Int;
}

private typedef RyuUInt128 = {
	var low:haxe.Int64;
	var high:haxe.Int64;
}

/** Binary64 to shortest-decimal conversion, implemented in ordinary Haxe. */
class Ryu {
	static inline final KIND_POSITIVE = 0;
	static inline final KIND_NEGATIVE = 1;
	static inline final KIND_NAN = 2;
	static inline final KIND_INFINITY = 3;
	static inline final KIND_NEGATIVE_INFINITY = 4;
	static inline final KIND_ZERO = 5;

	static inline final POW5_MULTIPLIER = 732923;
	static inline final POW5_MULTIPLIER_SHIFT = 20;
	static inline final LOG10_2_MULTIPLIER = 78913;
	static inline final LOG10_2_SHIFT = 18;
	static inline final LOG2_5_MULTIPLIER = 1217359;
	static inline final LOG2_5_SHIFT = 19;

	static inline final FRACTION_MASK_HIGH = 0x000fffff;
	static inline final SIGN_MASK_HIGH = 0x80000000;

	/** Convert an IEEE-754 value to its shortest round-tripping decimal. */
	public static function toDecimal(value:Float):RyuDecimal {
		var bits = FloatBits.toInt64(value);
		var sign = haxe.Int64.toInt(bits >>> 63);
		var fraction = bits & wide(FRACTION_MASK_HIGH, -1);
		var exponentField = haxe.Int64.toInt((bits >>> 52) & wide(0, 2047));

		if (exponentField == 2047) {
			if (fraction != wide(0, 0))
				return {significand: wide(0, 0), exponent: 0, kind: KIND_NAN};
			return {significand: wide(0, 0), exponent: 0, kind: sign == 0 ? KIND_INFINITY : KIND_NEGATIVE_INFINITY};
		}
		if (exponentField == 0 && fraction == wide(0, 0))
			return {significand: wide(0, 0), exponent: 0, kind: KIND_ZERO};

		var binaryExponent:Int;
		var significand:haxe.Int64;
		if (exponentField == 0) {
			binaryExponent = -1076;
			significand = fraction;
		} else {
			binaryExponent = exponentField - 1077;
			significand = fraction + wide(1 << 20, 0);
		}

		var acceptBounds = (significand & wide(0, 1)) == wide(0, 0);
		var mmShift = fraction != wide(0, 0) || exponentField <= 1 ? 1 : 0;
		var fourTimesSignificand = significand << 2;
		var inverseTrailingZeros = false;
		var centerTrailingZeros = false;
		var q:Int;
		var decimalExponent:Int;
		var tableIndex:Int;
		var binaryShift:Int;
		var tableAddress = RyuTables.address();

		var lower:haxe.Int64;
		var center:haxe.Int64;
		var upper:haxe.Int64;
		if (binaryExponent < 0) {
			var negativeBinaryExponent = -binaryExponent;
			q = (negativeBinaryExponent * POW5_MULTIPLIER) >>> POW5_MULTIPLIER_SHIFT;
			if (negativeBinaryExponent > 1)
				q--;
			decimalExponent = q + binaryExponent;
			tableIndex = negativeBinaryExponent - q;
			var log2PowerOfFive = ((tableIndex * LOG2_5_MULTIPLIER) >>> LOG2_5_SHIFT) + 1 - 125;
			binaryShift = q - log2PowerOfFive;
			var interval = multiplyShiftAll(significand, tableAddress, RyuTables.INVERSE_ENTRIES + tableIndex, binaryShift, mmShift);
			lower = interval.low;
			center = interval.high;
			upper = interval.top;
			if (q <= 1) {
				centerTrailingZeros = true;
				if (acceptBounds)
					inverseTrailingZeros = mmShift == 1;
				else
					upper = upper - wide(0, 1);
			} else if (q < 63) {
				centerTrailingZeros = (fourTimesSignificand & ((wide(0, 1) << q) - wide(0, 1))) == wide(0, 0);
			}
		} else {
			q = (binaryExponent * LOG10_2_MULTIPLIER) >>> LOG10_2_SHIFT;
			if (binaryExponent > 3)
				q--;
			decimalExponent = q;
			tableIndex = q;
			var log2PowerOfFive = ((q * LOG2_5_MULTIPLIER) >>> LOG2_5_SHIFT) + 125;
			binaryShift = -binaryExponent + q + log2PowerOfFive;
			var interval = multiplyShiftAll(significand, tableAddress, tableIndex, binaryShift, mmShift);
			lower = interval.low;
			center = interval.high;
			upper = interval.top;

			if (q <= 21) {
				if (fourTimesSignificand % wide(0, 5) == wide(0, 0)) {
					var factor = pow5Factor(fourTimesSignificand);
					centerTrailingZeros = q <= factor;
				} else if (acceptBounds) {
					var boundary = fourTimesSignificand - wide(0, 1) - wide(0, mmShift);
					var factor = pow5Factor(boundary);
					inverseTrailingZeros = q <= factor;
				} else {
					var factor = pow5Factor(fourTimesSignificand + wide(0, 2));
					upper -= wide(0, q <= factor ? 1 : 0);
				}
			}
		}

		var removedDigits = 0;
		var lastRemovedDigit = 0;
		var centerQuotient:haxe.Int64;
		if (inverseTrailingZeros || centerTrailingZeros) {
			while (true) {
				var upperQuotient = upper / wide(0, 10);
				var lowerQuotient = lower / wide(0, 10);
				if (upperQuotient <= lowerQuotient)
					break;

				var remainder = lower - lowerQuotient * wide(0, 10);
				var centerQuotient = center / wide(0, 10);
				lastRemovedDigit = haxe.Int64.toInt(center - centerQuotient * wide(0, 10));
				inverseTrailingZeros = inverseTrailingZeros && remainder == wide(0, 0);
				centerTrailingZeros = centerTrailingZeros && lastRemovedDigit == 0;
				center = centerQuotient;
				upper = upperQuotient;
				lower = lowerQuotient;
				removedDigits++;
			}

			if (inverseTrailingZeros) {
				while (lower % wide(0, 10) == wide(0, 0)) {
					var lowerQuotient = lower / wide(0, 10);
					var quotient = center / wide(0, 10);
					lastRemovedDigit = haxe.Int64.toInt(center - quotient * wide(0, 10));
					centerTrailingZeros = centerTrailingZeros && lastRemovedDigit == 0;
					upper /= wide(0, 10);
					center = quotient;
					lower = lowerQuotient;
					removedDigits++;
				}
			}

			if (centerTrailingZeros && lastRemovedDigit == 5 && (center & wide(0, 1)) == wide(0, 0))
				lastRemovedDigit = 4;
			var roundUp = (center == lower && !acceptBounds && !inverseTrailingZeros) || lastRemovedDigit >= 5;
			centerQuotient = center + wide(0, roundUp ? 1 : 0);
		} else {
			var roundUpForDiscardedDigits = false;
			var upperQuotient = upper / wide(0, 100);
			var lowerQuotient = lower / wide(0, 100);
			if (lowerQuotient < upperQuotient) {
				var quotient = center / wide(0, 100);
				var remainder = center - quotient * wide(0, 100);
				roundUpForDiscardedDigits = remainder >= wide(0, 50);
				center = quotient;
				upper = upperQuotient;
				lower = lowerQuotient;
				removedDigits += 2;
			}

			while (true) {
				upperQuotient = upper / wide(0, 10);
				lowerQuotient = lower / wide(0, 10);
				if (upperQuotient <= lowerQuotient)
					break;
				var quotient = center / wide(0, 10);
				var remainder = center - quotient * wide(0, 10);
				roundUpForDiscardedDigits = remainder >= wide(0, 5);
				center = quotient;
				upper = upperQuotient;
				lower = lowerQuotient;
				removedDigits++;
			}
			centerQuotient = center + wide(0, center == lower || roundUpForDiscardedDigits ? 1 : 0);
		}

		return {
			significand: centerQuotient,
			exponent: decimalExponent + removedDigits,
			kind: sign == 0 ? KIND_POSITIVE : KIND_NEGATIVE
		};
	}

	/** Format a value using Haxe's compact fixed/scientific notation thresholds. */
	public static function format(value:Float):String {
		var decimal = toDecimal(value);
		switch decimal.kind {
			case KIND_NAN:
				return "NaN";
			case KIND_INFINITY:
				return "Infinity";
			case KIND_NEGATIVE_INFINITY:
				return "-Infinity";
			case KIND_ZERO:
				return "0";
			default:
		}

		var characters:Array<Int> = [];
		var remaining = decimal.significand;
		while (remaining > wide(0, 0)) {
			var quotient = remaining / wide(0, 10);
			characters.push("0".code + haxe.Int64.toInt(remaining - quotient * wide(0, 10)));
			remaining = quotient;
		}
		if (characters.length == 0)
			characters.push("0".code);
		characters.reverse();

		var digitCount = characters.length;
		var decimalPointPosition = digitCount + decimal.exponent;
		var useScientificNotation = decimalPointPosition > 21 || decimalPointPosition <= -6;

		if (useScientificNotation) {
			if (digitCount > 1)
				characters.insert(1, ".".code);
			var exponent = decimalPointPosition - 1;
			characters.push("e".code);
			if (exponent < 0) {
				characters.push("-".code);
				exponent = -exponent;
			} else {
				characters.push("+".code);
			}
			appendUnsignedInt(characters, exponent);
		} else if (decimalPointPosition <= 0) {
			characters.insert(0, ".".code);
			characters.insert(0, "0".code);
			for (_ in 0... - decimalPointPosition)
				characters.insert(2, "0".code);
		} else if (decimalPointPosition < digitCount) {
			characters.insert(decimalPointPosition, ".".code);
		} else {
			for (_ in digitCount...decimalPointPosition)
				characters.push("0".code);
		}
		if (decimal.kind == KIND_NEGATIVE)
			characters.insert(0, "-".code);
		return RuntimeData.stringFromAscii(characters, 0, characters.length);
	}

	static function appendUnsignedInt(output:Array<Int>, value:Int):Void {
		if (value >= 100)
			output.push("0".code + Std.int(value / 100));
		if (value >= 10)
			output.push("0".code + Std.int(value / 10) % 10);
		output.push("0".code + value % 10);
	}

	static function multiplyShiftAll(significand:haxe.Int64, tableAddress:Int, tableIndex:Int, bitShift:Int,
			mmShift:Int):{low:haxe.Int64, high:haxe.Int64, top:haxe.Int64} {
		var fourTimesSignificand = significand << 2;
		var center = multiplyShift(fourTimesSignificand, tableAddress, tableIndex, bitShift);
		var upper = multiplyShift(fourTimesSignificand + wide(0, 2), tableAddress, tableIndex, bitShift);
		var lower = multiplyShift(fourTimesSignificand - wide(0, 1 + mmShift), tableAddress, tableIndex, bitShift);
		return {low: lower, high: center, top: upper};
	}

	static function multiplyShift(value:haxe.Int64, tableAddress:Int, tableIndex:Int, bitShift:Int):haxe.Int64 {
		var offset = tableIndex * 4;
		var tableLow = haxe.Int64.make(RuntimeData.loadI32(tableAddress + (offset + 1) * 4), RuntimeData.loadI32(tableAddress + offset * 4));
		var tableHigh = haxe.Int64.make(RuntimeData.loadI32(tableAddress + (offset + 3) * 4), RuntimeData.loadI32(tableAddress + (offset + 2) * 4));
		var upperProduct = unsignedMultiply128(value, tableHigh);
		var lowerProduct = unsignedMultiply128(value, tableLow);
		var shiftedLowWord = upperProduct.low + lowerProduct.high;
		var carry = unsignedLess(shiftedLowWord, upperProduct.low) ? wide(0, 1) : wide(0, 0);
		var highProduct = upperProduct.high + carry;
		var complementaryShift = bitShift - 64;
		return (highProduct << (64 - complementaryShift)) | (shiftedLowWord >>> complementaryShift);
	}

	static function unsignedMultiply128(left:haxe.Int64, right:haxe.Int64):RyuUInt128 {
		var mask = wide(0, -1);
		var leftLow = left & mask;
		var leftHigh = left >>> 32;
		var rightLow = right & mask;
		var rightHigh = right >>> 32;
		var lowProduct = leftLow * rightLow;
		var leftLowRightHighProduct = leftLow * rightHigh;
		var leftHighRightLowProduct = leftHigh * rightLow;
		var highProduct = leftHigh * rightHigh;

		var lowWord = lowProduct & mask;
		var crossTerm = leftHighRightLowProduct + (lowProduct >>> 32);
		var crossTermLowWord = crossTerm & mask;
		var crossTermCarry = crossTerm >>> 32;
		var middleTerm = leftLowRightHighProduct + crossTermLowWord;
		var middleTermLowWord = middleTerm & mask;
		var middleTermCarry = middleTerm >>> 32;
		var productLow = (middleTermLowWord << 32) | lowWord;
		var productHigh = highProduct + crossTermCarry + middleTermCarry;
		return {low: productLow, high: productHigh};
	}

	static function pow5Factor(value:haxe.Int64):Int {
		var count = 0;
		while (value % wide(0, 5) == wide(0, 0)) {
			value /= wide(0, 5);
			count++;
		}
		return count;
	}

	static inline function unsignedLess(left:haxe.Int64, right:haxe.Int64):Bool {
		var signBit = wide(SIGN_MASK_HIGH, 0);
		return (left ^ signBit) < (right ^ signBit);
	}

	static inline function wide(high:Int, low:Int):haxe.Int64
		return haxe.Int64.make(high, low);
}
