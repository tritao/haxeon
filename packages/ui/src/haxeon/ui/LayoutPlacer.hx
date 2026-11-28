package haxeon.ui;

/**
 * Places an absolutely positioned node during layout (ADR 0009), after its parent is placed and the scroll offsets of
 * the nodes before it have settled, from state outside the tree: a scrollbar from its scroll controller. Its subtree is
 * then laid out at the size it gives.
 */
interface LayoutPlacer {
	/** Sets `out` to the node's box within its parent's, which is `parentWidth` by `parentHeight`. */
	function place(parentWidth:Float, parentHeight:Float, out:LayoutPlacement):Void;
}

/** Where a `LayoutPlacer` puts its node: its box relative to its parent's, and whether it shows. */
class LayoutPlacement {
	public var x:Float = 0.0;
	public var y:Float = 0.0;
	public var width:Float = 0.0;
	public var height:Float = 0.0;

	/** Whether the node and its subtree are drawn and hit; a hidden one keeps its box. */
	public var shown:Bool = true;

	public function new() {}
}
