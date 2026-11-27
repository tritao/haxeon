package haxeon;

/** Structural equality generated from the static type at each call site. */
class Equality {
	/** Whether `left` and `right` are equal, as `T`'s `Equatable` conformance compares them. */
	public static extern function equals<T>(left:T, right:T):Bool;

	/**
	 * Whether a reactive value changing from `left` to `right` is no change: `equals` where `T` is `Equatable`, else
	 * identity, with every NaN the same.
	 */
	public static extern function sameForChange<T>(left:T, right:T):Bool;
}
