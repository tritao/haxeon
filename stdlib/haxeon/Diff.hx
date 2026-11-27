package haxeon;

/** Compiler-generated copying, field masks, updates and snapshot fingerprints for Diffable types. */
class Diff {
	/** A copy of `value`, field by field, as its `Diffable` conformance declares. */
	public static function copy<T:Diffable>(value:T):T throw "Diff.copy must be lowered by the compiler";

	/** A fieldwise snapshot fingerprint, not a map-key hash contract. Each stored field must conform to Hashable. */
	public static function fingerprint<T:Diffable>(value:T):Int throw "Diff.fingerprint must be lowered by the compiler";
}
