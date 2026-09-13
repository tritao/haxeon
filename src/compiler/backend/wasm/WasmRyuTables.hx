package compiler.backend.wasm;

import haxe.io.Bytes;

/**
 * Builds the exact split powers used by Ryū's binary64 conversion.
 *
 * Generating them with small base-2^16 limbs keeps the compiler host independent
 * of BigInt support, while the resulting 10.7 KiB table is embedded as Wasm data.
 */
class WasmRyuTables {
	public static inline final INVERSE_ENTRIES = 342;
	public static inline final POWER_ENTRIES = 326;
	static var cached:Null<Bytes>;

	public static function bytes():Bytes {
		if (cached != null)
			return cached;
		var result = Bytes.alloc((INVERSE_ENTRIES + POWER_ENTRIES) * 16),
			power:Array<Int> = [1];
		for (index in 0...INVERSE_ENTRIES) {
			write128(result, index * 16, inverseMultiplier(power));
			multiplySmall(power, 5);
		}
		power = [1];
		for (index in 0...POWER_ENTRIES) {
			write128(result, (INVERSE_ENTRIES + index) * 16, powerMultiplier(power));
			multiplySmall(power, 5);
		}
		cached = result;
		return result;
	}

	static function inverseMultiplier(power:Array<Int>):Array<Int> {
		var numerator = shiftLeft([1], bitLength(power) - 1 + 125),
			quotient = divide(numerator, power);
		addSmall(quotient, 1);
		return quotient;
	}

	static function powerMultiplier(power:Array<Int>):Array<Int> {
		var shift = bitLength(power) - 125;
		return shift >= 0 ? shiftRight(power, shift) : shiftLeft(power, -shift);
	}

	static function write128(bytes:Bytes, offset:Int, value:Array<Int>):Void {
		for (word in 0...8) {
			var digit = word < value.length ? value[word] : 0;
			bytes.set(offset + word * 2, digit & 0xff);
			bytes.set(offset + word * 2 + 1, digit >>> 8);
		}
	}

	static function multiplySmall(value:Array<Int>, factor:Int):Void {
		var carry = 0;
		for (index in 0...value.length) {
			var product = value[index] * factor + carry;
			value[index] = product & 0xffff;
			carry = product >>> 16;
		}
		while (carry != 0) {
			value.push(carry & 0xffff);
			carry = carry >>> 16;
		}
	}

	static function addSmall(value:Array<Int>, amount:Int):Void {
		var carry = amount, index = 0;
		while (carry != 0) {
			if (index == value.length)
				value.push(0);
			var sum = value[index] + carry;
			value[index] = sum & 0xffff;
			carry = sum >>> 16;
			index++;
		}
	}

	static function shiftLeft(value:Array<Int>, bits:Int):Array<Int> {
		if (bits == 0)
			return value.copy();
		var words = bits >>> 4, remainder = bits & 15, result:Array<Int> = [];
		for (_ in 0...words)
			result.push(0);
		var carry = 0;
		for (digit in value) {
			var shifted = (digit << remainder) | carry;
			result.push(shifted & 0xffff);
			carry = shifted >>> 16;
		}
		if (carry != 0)
			result.push(carry);
		return trim(result);
	}

	static function shiftRight(value:Array<Int>, bits:Int):Array<Int> {
		if (bits == 0)
			return value.copy();
		var words = bits >>> 4, remainder = bits & 15, result:Array<Int> = [];
		for (index in words...value.length) {
			var digit = value[index] >>> remainder;
			if (remainder != 0 && index + 1 < value.length)
				digit |= value[index + 1] << (16 - remainder);
			result.push(digit & 0xffff);
		}
		return trim(result);
	}

	static function divide(numerator:Array<Int>, denominator:Array<Int>):Array<Int> {
		var remainder = numerator.copy(),
			shift = bitLength(numerator) - bitLength(denominator),
			divisor = shiftLeft(denominator, shift),
			quotient:Array<Int> = [];
		for (offset in 0...shift + 1) {
			if (compare(remainder, divisor) >= 0) {
				subtract(remainder, divisor);
				setBit(quotient, shift - offset);
			}
			divisor = shiftRight(divisor, 1);
		}
		return trim(quotient);
	}

	static function setBit(value:Array<Int>, bit:Int):Void {
		var word = bit >>> 4;
		while (value.length <= word)
			value.push(0);
		value[word] |= 1 << (bit & 15);
	}

	static function subtract(left:Array<Int>, right:Array<Int>):Void {
		var borrow = 0;
		for (index in 0...left.length) {
			var difference = left[index] - (index < right.length ? right[index] : 0) - borrow;
			if (difference < 0) {
				difference += 0x10000;
				borrow = 1;
			} else {
				borrow = 0;
			}
			left[index] = difference;
		}
		trim(left);
	}

	static function compare(left:Array<Int>, right:Array<Int>):Int {
		var leftLength = effectiveLength(left),
			rightLength = effectiveLength(right);
		if (leftLength != rightLength)
			return leftLength < rightLength ? -1 : 1;
		var index = leftLength;
		while (index-- > 0)
			if (left[index] != right[index])
				return left[index] < right[index] ? -1 : 1;
		return 0;
	}

	static function bitLength(value:Array<Int>):Int {
		var length = effectiveLength(value);
		if (length == 0)
			return 0;
		var high = value[length - 1], bits = 0;
		while (high != 0) {
			high = high >>> 1;
			bits++;
		}
		return (length - 1) * 16 + bits;
	}

	static function effectiveLength(value:Array<Int>):Int {
		var length = value.length;
		while (length > 0 && value[length - 1] == 0)
			length--;
		return length;
	}

	static function trim(value:Array<Int>):Array<Int> {
		while (value.length > 1 && value[value.length - 1] == 0)
			value.pop();
		return value;
	}
}
