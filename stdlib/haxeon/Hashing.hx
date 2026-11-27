package haxeon;

/** Hash operations for values with declared Hashable conformance. */
class Hashing {
	/** The hash of `value`, from its `Hashable` conformance, the same for all uses of the value. */
	public static extern function hash<T:Hashable>(value:T):Int;

	/** Whether `left` and `right` are the same map key: a reflexive equivalence, under which every Float NaN is the same. */
	public static extern function keyEquals<T:Hashable>(left:T, right:T):Bool;

	/** `hash` combined with `value`, as `hash * 31 + value`: what a conformance's hash folds each field into. */
	public static inline function mix(hash:Int, value:Int):Int
		return hash * 31 + value;
}
