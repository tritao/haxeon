package haxeon.ui;

/** Render/layout node submitted to NativeUI. Haxe semantics live above it. */
class LayoutNode {
	public final id:Int;
	public var visualKind:LayoutVisualKind;
	public final style:LayoutStyle;
	public var text:String;
	@:isVar public var textColor(get, set):Color;
	/**
	 * Most nodes never show text, so absent values use shared immutable defaults. Reading these properties allocates
	 * nothing; assigning a complete style stores its value inline in the optional slot.
	 */
	public var textStyle(get, set):TextStyle;
	public var paragraphStyle(get, set):ParagraphStyle;
	var ownTextStyles:Null<LayoutTextStyles> = null;
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
	/** Intrinsic input version. Sampled from an attached provider before submit; otherwise set by its caller. */
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

	function get_textColor():Color {
		var binding = PaintBindings.node(this);
		if (binding == null) return textColor;
		var slot = binding.store.at(binding.index, binding.generation);
		return new Color(slot.ref.textRed, slot.ref.textGreen, slot.ref.textBlue, slot.ref.textAlpha);
	}

	function set_textColor(value:Color):Color {
		var binding = PaintBindings.node(this);
		if (binding == null) return textColor = value;
		while (binding != null) {
			binding.store.setTextColor(binding.index, binding.generation, value.red, value.green, value.blue, value.alpha);
			binding = binding.nextNode;
		}
		return value;
	}

	function get_textStyle():TextStyle return peekTextStyle();

	function set_textStyle(value:TextStyle):TextStyle {
		var own = ownTextStyles;
		if (own == null) {
			own = new LayoutTextStyles(DefaultTextStyle, DefaultParagraphStyle);
			ownTextStyles = own;
		}
		own.text = value;
		return value;
	}

	function get_paragraphStyle():ParagraphStyle return peekParagraphStyle();

	function set_paragraphStyle(value:ParagraphStyle):ParagraphStyle {
		var own = ownTextStyles;
		if (own == null) {
			own = new LayoutTextStyles(DefaultTextStyle, DefaultParagraphStyle);
			ownTextStyles = own;
		}
		own.paragraph = value;
		return value;
	}

	/** Text style value: the node's own, or the shared immutable default. Allocates nothing. */
	public function peekTextStyle():TextStyle {
		var own = ownTextStyles;
		return own == null ? DefaultTextStyle : own.text;
	}

	/** Paragraph style value: the node's own, or the shared immutable default. Allocates nothing. */
	public function peekParagraphStyle():ParagraphStyle {
		var own = ownTextStyles;
		return own == null ? DefaultParagraphStyle : own.paragraph;
	}

	/** Copy immutable typography into a comparison prior without allocating default styles for boxes. */
	public function copyTextStylesTo(target:LayoutNode):Void {
		var own = ownTextStyles;
		if (own == null) {
			target.ownTextStyles = null;
		} else {
			var targetOwn = target.ownTextStyles;
			if (targetOwn == null)
				target.ownTextStyles = new LayoutTextStyles(own.text, own.paragraph);
			else {
				targetOwn.text = own.text;
				targetOwn.paragraph = own.paragraph;
			}
		}
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

/** Lazily allocated because most layout nodes do not carry text. Its immutable values stay inline in this holder. */
private class LayoutTextStyles {
	public var text:TextStyle;
	public var paragraph:ParagraphStyle;

	public function new(text:TextStyle, paragraph:ParagraphStyle) {
		this.text = text;
		this.paragraph = paragraph;
	}
}
