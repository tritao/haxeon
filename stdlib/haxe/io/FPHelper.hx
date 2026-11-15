package haxe.io;

/** The IEEE 754 bits of floating-point numbers, as in Haxe. */
class FPHelper {
	/** The bits of `f` rounded to a 32-bit float. */
	public static function floatToI32(f:Float):Int {
		var bytes = Bytes.alloc(4);
		bytes.setFloat(0, f);
		return bytes.getInt32(0);
	}

	/** The 32-bit float whose bits are `i`. */
	public static function i32ToFloat(i:Int):Float {
		var bytes = Bytes.alloc(4);
		bytes.setInt32(0, i);
		return bytes.getFloat(0);
	}

	/** The bits of the double `v`. */
	public static inline function doubleToI64(v:Float):haxe.Int64
		return runtime.FloatBits.toInt64(v);

	/** The double whose bits are `high` (most significant) and `low`, as Haxe takes them. */
	public static inline function i64ToDouble(low:Int, high:Int):Float
		return runtime.FloatBits.fromInt64(haxe.Int64.make(high, low));
}
