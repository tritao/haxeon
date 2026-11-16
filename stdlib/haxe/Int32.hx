package haxe;

/** Haxe's 32-bit integer: an Int, which already wraps at 32 bits on every Haxeon target. */
abstract Int32(Int) from Int to Int {
	/** Compares `a` and `b` as unsigned 32-bit integers: negative, zero or positive as `a` is less, equal or greater. */
	public static function ucompare(a:Int32, b:Int32):Int {
		var left = (a:Int) ^ 0x80000000, right = (b:Int) ^ 0x80000000;
		return left < right ? -1 : left > right ? 1 : 0;
	}
}
