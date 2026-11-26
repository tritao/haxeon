package haxeon;

/**
 * A switch over a closed set met a value none of its cases name: one a `cast` made, or a code from native code or the
 * wire that skipped `fromRaw`. It is a bug, so nothing is expected to catch it but a boundary that reports it.
 */
class UnmatchedValue extends haxe.Exception {
	/** An error saying what was unmatched, such as "Unmatched Kind value". */
	@:pure public function new(message:String)
		super(message);
}
