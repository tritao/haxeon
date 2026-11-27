package haxeon;

/** Compiler-generated copying, field masks, updates and snapshot fingerprints for Diffable types. */
class Diff {
	/** A copy of `value`, field by field, as its `Diffable` conformance declares. */
	public static extern function copy<T:Diffable>(value:T):T;

	/** The fields that differ between `left` and `right`, one bit per field in declaration order (`bit` gives each). */
	public static extern function mask<T:Diffable>(left:T, right:T):Int;

	/** Assigns to `target` each field that differs between `before` and `after`, from `after`; gives the fields it assigned. */
	public static extern function apply<T:Diffable>(target:T, before:T, after:T):Int;

	/** The bit of the field `path` names in a mask: `Diff.bit(\Style.width)`. A constant. */
	public static extern function bit<T:Diffable, V>(path:KeyPath<T, V>):Int;

	/** The mask of every field of `T`: `Diff.all<Style>()`. A constant. */
	public static extern function all<T:Diffable>():Int;

	/** A fieldwise snapshot fingerprint, not a map-key hash contract. Each stored field must conform to Hashable. */
	public static extern function fingerprint<T:Diffable>(value:T):Int;
}
