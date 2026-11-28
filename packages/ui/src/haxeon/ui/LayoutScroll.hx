package haxeon.ui;

/**
 * The offset a scroll container's content moves by, settled while it is laid out (ADR 0009): once the viewport's size and
 * the content's are known, so clamping the offset to them, or scrolling a node of the content into view, takes no second
 * layout. A `LayoutNode` with one is the content, and its parent the viewport.
 */
interface LayoutScroll {
	/**
	 * Settles the offset for a `viewportWidth` by `viewportHeight` viewport over content of the given size; `content` finds
	 * where the content's nodes are.
	 */
	function settle(viewportWidth:Float, viewportHeight:Float, contentWidth:Float, contentHeight:Float,
			content:LayoutLocator):Void;

	/** How far the content moves left. */
	function scrollX():Float;

	/** How far the content moves up. */
	function scrollY():Float;
}

/** Finds where a node of a scroll container's content is, relative to the content, while layout settles its scroll. */
class LayoutLocator {
	/** The box of the node last found, relative to the content's box. */
	public var x(default, null):Float = 0.0;
	public var y(default, null):Float = 0.0;
	public var width(default, null):Float = 0.0;
	public var height(default, null):Float = 0.0;

	final find:(id:Int, out:LayoutLocator) -> Bool;

	@:allow(haxeon.ui.layout.LayoutSolver)
	function new(find:(id:Int, out:LayoutLocator) -> Bool) {
		this.find = find;
	}

	/** Whether the node whose ID is `id` is in the content; when it is, `x`, `y`, `width` and `height` are its box. */
	public function locate(id:Int):Bool return find(id, this);

	@:allow(haxeon.ui.layout.LayoutSolver)
	function set(x:Float, y:Float, width:Float, height:Float):Void {
		this.x = x;
		this.y = y;
		this.width = width;
		this.height = height;
	}
}
