package haxeon.ui;

/** One live node's association with a style and a native paint slot. */
@:noCompletion
class PaintBinding {
	public final style:LayoutStyle;
	public final node:LayoutNode;
	public final store:PaintStore;
	public final index:Int;
	public final generation:Int;
	public var nextStyle:Null<PaintBinding>;
	public var nextNode:Null<PaintBinding>;

	public function new(style:LayoutStyle, node:LayoutNode, store:PaintStore, index:Int, generation:Int) {
		this.style = style;
		this.node = node;
		this.store = store;
		this.index = index;
		this.generation = generation;
		nextStyle = null;
		nextNode = null;
	}
}
