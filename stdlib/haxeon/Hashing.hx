package haxeon;

/** Hash operations for values with declared Hashable conformance. */
class Hashing {
	/** Compiler intrinsic: the selected conformance supplies one hash for all uses of a value. */
	public static function hash<T:Hashable>(value:T):Int
		throw "Hashing.hash must be lowered by the compiler";

	public static inline function mix(hash:Int, value:Int):Int
		return hash * 31 + value;

	/** Hash of a Float consistent with `==`, treating 0.0 and -0.0 alike. */
	public static function hashFloat(value:Float):Int {
		if (value != value)
			return 0x7fc00000;
		if (value == 0.0)
			return 0;
		var whole = value >= 2147483647.0 ? 2147483647 : value <= -2147483647.0 ? -2147483647 : Std.int(value);
		return whole * 31 + Std.int((value - whole) * 16777216.0);
	}

	public static function hashString(value:Null<String>):Int {
		if (value == null)
			return 0;
		var hash = value.length;
		for (index in 0...value.length)
			hash = hash * 31 + StringTools.fastCodeAt(value, index);
		return hash;
	}
}
