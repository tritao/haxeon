package runtime;

/** Bit-level operations used by source implementations of numeric algorithms. */
extern class FloatBits {
	@:hlNative("haxeon_runtime", "__f64_to_i64_bits")
	public static function toInt64(value:Float):haxe.Int64;

	@:hlNative("haxeon_runtime", "__i64_to_f64_bits")
	public static function fromInt64(value:haxe.Int64):Float;
}
