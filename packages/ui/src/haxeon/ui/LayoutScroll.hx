package haxeon.ui;

/**
 * The offset a scroll container's content moves by, settled while it is laid out (ADR 0009): once the viewport's size and
 * the content's are known, so clamping the offset to them takes no second layout. A `LayoutNode` with one is the
 * content, and its parent the viewport.
 */
interface LayoutScroll {
	/** Settles the offset for a `viewportWidth` by `viewportHeight` viewport over content of the given size. */
	function settle(viewportWidth:Float, viewportHeight:Float, contentWidth:Float, contentHeight:Float):Void;

	/** How far the content moves left. */
	function scrollX():Float;

	/** How far the content moves up. */
	function scrollY():Float;
}
