package haxe;

/** `value.low`: the low 32 bits, as Haxe's Int64.low. The compiler maps the field to this function (`PlatformAbi`). */
function int64Low(value:haxe.Int64):Int
	return Int64.toInt(value);

/** `value.high`: the high 32 bits, as Haxe's Int64.high. */
function int64High(value:haxe.Int64):Int
	return Int64.toInt(Int64.shr(value, 32));

/**
 * A signed 64-bit integer, in two's complement: arithmetic wraps on overflow. The operators work on it as on `Int` (`a + b`,
 * `a << 3`, `a < b`), as do these functions.
 */
extern class Int64 {
	/**
	 * The decimal integer `value`, with an optional sign and nothing else. Throws when it is not one, or does not fit
	 * in 64 bits.
	 */
	@:hlNative("haxeon_runtime", "__int64_parse")
	public static function parseString(value:String):haxe.Int64;

	/** `value` in decimal. */
	@:hlNative("haxeon_runtime", "__int64_to_string")
	public static function toStr(value:haxe.Int64):String;

	/** Converts to a Float; every integer with |value| < 2^53 is exact. */
	@:hlNative("haxeon_runtime", "__int64_to_float")
	public static function toFloat(value:haxe.Int64):Float;

	/** `value`, sign-extended. */
	@:hlNative("haxeon_runtime", "__int64_of_int")
	public static function ofInt(value:Int):haxe.Int64;

	/** `value` truncated toward zero. A value outside the range, or NaN, gives an unspecified result. */
	@:hlNative("haxeon_runtime", "__int64_from_float")
	public static function fromFloat(value:Float):haxe.Int64;

	/** The integer whose high 32 bits are `high` and low 32 bits are `low`. */
	@:hlNative("haxeon_runtime", "__int64_make")
	public static function make(high:Int, low:Int):haxe.Int64;

	/** The low 32 bits of `value`, as an `Int`: `value` itself when it fits. */
	@:hlNative("haxeon_runtime", "__int64_to_int")
	public static function toInt(value:haxe.Int64):Int;

	/** `left + right`, wrapping on overflow. */
	@:hlNative("haxeon_runtime", "__int64_add")
	public static function add(left:haxe.Int64, right:haxe.Int64):haxe.Int64;

	/** `left - right`, wrapping on overflow. */
	@:hlNative("haxeon_runtime", "__int64_sub")
	public static function sub(left:haxe.Int64, right:haxe.Int64):haxe.Int64;

	/** `-value`; the minimum stays the minimum. */
	@:hlNative("haxeon_runtime", "__int64_neg")
	public static function neg(value:haxe.Int64):haxe.Int64;

	/** `left * right`, wrapping on overflow. */
	@:hlNative("haxeon_runtime", "__int64_mul")
	public static function mul(left:haxe.Int64, right:haxe.Int64):haxe.Int64;

	/** Truncating division, as Haxe's: dividing by zero throws; the minimum divided by -1 wraps to the minimum. */
	@:hlNative("haxeon_runtime", "__int64_div")
	public static function div(dividend:haxe.Int64, divisor:haxe.Int64):haxe.Int64;

	/** The remainder of `div`, with the dividend's sign. */
	@:hlNative("haxeon_runtime", "__int64_mod")
	public static function mod(dividend:haxe.Int64, divisor:haxe.Int64):haxe.Int64;

	/** The bitwise and of `left` and `right`. */
	@:hlNative("haxeon_runtime", "__int64_and")
	public static function and(left:haxe.Int64, right:haxe.Int64):haxe.Int64;

	/** The bitwise or of `left` and `right`. */
	@:hlNative("haxeon_runtime", "__int64_or")
	public static function or(left:haxe.Int64, right:haxe.Int64):haxe.Int64;

	/** The bitwise exclusive or of `left` and `right`. */
	@:hlNative("haxeon_runtime", "__int64_xor")
	public static function xor(left:haxe.Int64, right:haxe.Int64):haxe.Int64;

	/** `value` shifted left by `shift` bits; 0 for a shift outside 0 to 63. */
	@:hlNative("haxeon_runtime", "__int64_shl")
	public static function shl(value:haxe.Int64, shift:Int):haxe.Int64;

	/** `value` shifted right by `shift` bits, keeping its sign; 0 or -1 for a shift outside 0 to 63. */
	@:hlNative("haxeon_runtime", "__int64_shr")
	public static function shr(value:haxe.Int64, shift:Int):haxe.Int64;

	/** `value` shifted right by `shift` bits, filling with zeros; 0 for a shift outside 0 to 63. */
	@:hlNative("haxeon_runtime", "__int64_ushr")
	public static function ushr(value:haxe.Int64, shift:Int):haxe.Int64;

	/** -1, 0 or 1 as `left` is less than, equal to or greater than `right`, as signed integers. */
	@:hlNative("haxeon_runtime", "__int64_compare")
	public static function compare(left:haxe.Int64, right:haxe.Int64):Int;

	/** -1, 0 or 1 as `left` is less than, equal to or greater than `right`, as unsigned integers. */
	@:hlNative("haxeon_runtime", "__int64_unsigned_compare")
	public static function ucompare(left:haxe.Int64, right:haxe.Int64):Int;
}
