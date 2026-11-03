package haxeon;

/** Hash operations for values with declared Hashable conformance. */
class Hashing {
	/** Compiler intrinsic: the selected conformance supplies one hash for all uses of a value. */
	public static function hash<T:Hashable>(value:T):Int
		throw "Hashing.hash must be lowered by the compiler";

	public static inline function mix(hash:Int, value:Int):Int
		return hash * 31 + value;
}
