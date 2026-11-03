package haxeon;

/** Hash operations for values with declared Hashable conformance. */
class Hashing {
	/** Compiler intrinsic: the selected conformance supplies one hash for all uses of a value. */
	public static function hash<T:Hashable>(value:T):Int
		throw "Hashing.hash must be lowered by the compiler";

	/** Compiler intrinsic: map keys use a reflexive equivalence, including all Float NaNs. */
	public static function keyEquals<T:Hashable>(left:T, right:T):Bool
		throw "Hashing.keyEquals must be lowered by the compiler";

	public static inline function mix(hash:Int, value:Int):Int
		return hash * 31 + value;
}
