package haxeon.ui;

/** Render/layout node submitted to NativeUI. Haxe semantics live above it. */
class LayoutNode {
	public final id:Int;
	public var visualKind:LayoutVisualKind;
	public final style:LayoutStyle;
	public var text:String;
	public var textColor:Color;
	/**
	 * Most nodes never show text, so a node allocates its own text and paragraph style on first use. Anything that reads
	 * these for every node must use `peekTextStyle` and `peekParagraphStyle`, which allocate nothing.
	 */
	public var textStyle(get, never):TextStyle;
	public var paragraphStyle(get, never):ParagraphStyle;
	var ownTextStyle:Null<TextStyle> = null;
	var ownParagraphStyle:Null<ParagraphStyle> = null;
	/** Color is immutable, and the styles below are only ever read: every node without its own starts from these. */
	static final DefaultTextColor:Color = Color.rgba(1.0, 1.0, 1.0, 1.0);
	static final DefaultTextStyle:TextStyle = new TextStyle();
	static final DefaultParagraphStyle:ParagraphStyle = new ParagraphStyle();
	/** Whether this node's own resolved bounds participate in geometric picking. */
	public var hitSelf:Bool;
	/** Whether descendants participate in geometric picking below this node. */
	public var hitChildren:Bool;
	/** Optional external content measured when this node is Custom. */
	public var intrinsicContent:Null<LayoutContent>;
	/** Invalidates native intrinsic measurement when no content object is attached. */
	public var measureVersion:Int;
	/** Paint/text revision consumed by native raster-cache identity. */
	public var contentRevision:Int;
	/** Resolved bounds/transform/clip revision shared by native scene consumers. */
	public var geometryRevision:Int;
	/** Opacity/effects revision shared by native scene consumers. */
	public var compositeRevision:Int;
	/** Shared and empty until the first `add`, so leaves allocate no array; change it only through `add` and `remove`. */
	public var children(default, null):Array<LayoutNode>;
	static final NoChildren:Array<LayoutNode> = [];
	/** Set by LayoutTransaction to the encode that last visited this node, so duplicates are found without a lookup table. */
	@:allow(LayoutTransaction)
	var encodeStamp:Int;

	public function new(id:Int, visualKind:LayoutVisualKind = LayoutVisualKind.Box,
			?style:LayoutStyle) {
		if (id <= 0)
			throw "Layout node IDs must be positive";
		this.id = id;
		this.visualKind = visualKind;
		this.style = style == null ? new LayoutStyle() : style;
		text = "";
		textColor = DefaultTextColor;
		hitSelf = true;
		hitChildren = true;
		intrinsicContent = null;
		measureVersion = 0;
		contentRevision = 0;
		geometryRevision = 0;
		compositeRevision = 0;
		encodeStamp = 0;
		children = NoChildren;
	}

	function get_textStyle():TextStyle {
		var own = ownTextStyle;
		if (own == null) {
			own = new TextStyle();
			ownTextStyle = own;
		}
		return own;
	}

	function get_paragraphStyle():ParagraphStyle {
		var own = ownParagraphStyle;
		if (own == null) {
			own = new ParagraphStyle();
			ownParagraphStyle = own;
		}
		return own;
	}

	/** Read-only view of the text style: the node's own, or a shared default that must never be changed. Allocates nothing. */
	public function peekTextStyle():TextStyle {
		var own = ownTextStyle;
		return own == null ? DefaultTextStyle : own;
	}

	/** Read-only view of the paragraph style: the node's own, or a shared default that must never be changed. Allocates nothing. */
	public function peekParagraphStyle():ParagraphStyle {
		var own = ownParagraphStyle;
		return own == null ? DefaultParagraphStyle : own;
	}

	public function add(child:LayoutNode):LayoutNode {
		if (child == null || child == this)
			throw "A layout node cannot contain itself";
		if (children == NoChildren)
			children = [];
		children.push(child);
		return child;
	}

	public function remove(child:LayoutNode):Bool {
		return child != null && children.remove(child);
	}

	public static function box(id:Int, ?style:LayoutStyle):LayoutNode
		return new LayoutNode(id, LayoutVisualKind.Box, style);

	public static function textNode(id:Int, value:String, ?style:LayoutStyle):LayoutNode {
		var node = new LayoutNode(id, LayoutVisualKind.Text, style);
		node.text = value == null ? "" : value;
		return node;
	}

	/** Creates a Custom node backed by a reusable intrinsic content provider. */
	public static function custom(id:Int, content:LayoutContent, ?style:LayoutStyle):LayoutNode {
		if (content == null)
			throw "Custom layout nodes require intrinsic content";
		var node = new LayoutNode(id, LayoutVisualKind.Custom, style);
		node.intrinsicContent = content;
		return node;
	}
}
