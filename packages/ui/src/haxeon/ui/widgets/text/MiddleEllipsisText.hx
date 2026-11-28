package haxeon.ui.widgets.text;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.TextStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.core.ViewRoot;

/**
 * Fits a single-line label with an ellipsis, preserving both ends by default or only the prefix. Layout cuts the text at
 * the width it gives the label (`LayoutNode.truncation`); its accessible label stays the whole text.
 */
class MiddleEllipsisText implements View {
	/** Identifies the label among its siblings. */
	public final key:String;

	/** The full text. */
	public final value:String;

	/** Whether the ellipsis goes in the middle, keeping both ends, or at the end, keeping the start. */
	public final middle:Bool;

	/** Changes to the inherited text style. */
	public final textStyle:Null<TextStyleOverride>;

	/** Whether the last layout had to shorten the text. */
	public var truncated(get, never):Bool;

	var node:Null<RenderNode> = null;

	/** A single line showing `value`, shortened with an ellipsis when it does not fit. */
	public function new(key:String, value:String, middle:Bool = true, ?textStyle:TextStyleOverride) {
		this.key = key;
		this.value = value;
		this.middle = middle;
		this.textStyle = textStyle;
	}

	function get_truncated():Bool {
		var built = node;
		return built != null && built.layout.shownText != null;
	}

	public function build(context:BuildContext):ViewRoot return makeNode(context);

	/** The text node itself, for a widget that shows it as its own text, as an unfocused text field does. */
	public function makeNode(context:BuildContext):RenderNode {
		return context.withScope(new Key(key), function() {
			var style = new LayoutStyle();
			style.width = LayoutAxis.grow();
			style.clipHorizontal = true;
			var labelOverride = TextStyleOverride.combine(textStyle, TextStyleOverride.paragraph(TextWrap.None));
			var built = new Text(value, style, null, labelOverride).makeNode(context);
			built.layout.truncation = middle ? TextTruncation.Middle : TextTruncation.End;
			if (built.semantics != null) built.semantics.label = value;
			node = built;
			return built;
		});
	}
}
