package haxeon.ui.semantics;

/**
	A value `Semantics` defers: read only when a consumer asks for it, and compared by revision instead of by content, so
	an editor's whole document is neither assembled nor compared on frames where it did not change.
**/
interface SemanticsValueSource {
	/** The current value. */
	function semanticsValue():String;

	/** A number that changes whenever `semanticsValue` would return something different. */
	function semanticsValueRevision():Int;
}
