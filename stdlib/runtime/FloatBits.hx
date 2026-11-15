package runtime;

/** Bit-level operations used by source implementations of numeric algorithms. */
extern class FloatBits {
	@:hlNative("haxeon_runtime", "__f64_to_i64_bits")
	public static function toInt64(value:Float):haxe.Int64;

	@:hlNative("haxeon_runtime", "__i64_to_f64_bits")
	public static function fromInt64(value:haxe.Int64):Float;

	/** The bits of `value` rounded to a 32-bit float. */
	@:hlNative("haxeon_runtime", "__float_to_f32_bits")
	public static function toInt32(value:Float):Int;

	/** The 32-bit float whose bits are `value`. */
	@:hlNative("haxeon_runtime", "__f32_bits_to_float")
	public static function fromInt32(value:Int):Float;
}
