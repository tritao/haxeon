package haxeon.ui.widgets.text;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.style.StyleIdentity;

import haxeon.ui.Color;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.core.WidgetId;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.theme.TextRole;

/** Text view backed by the NativeUI/Skribidi text layout primitive. */
class Text implements View {
	/** The text shown. */
	public final value:String;

	/** The text's box. */
	public final style:LayoutStyle;

	/** The text color; the role's when null. */
	public final color:Null<Color>;

	/** Changes to the inherited text style. */
	public final textStyle:Null<TextStyleOverride>;

	/** The theme text role it takes its typography from, such as body or heading. */
	public final role:TextRole;

	/** Text showing `value`, in the theme's body style unless `role` or `textStyle` say otherwise. */
	public function new(value:String, ?style:LayoutStyle, ?color:Color, ?textStyle:TextStyleOverride, ?role:TextRole) {
		this.value = value == null ? "" : value;
		this.style = style == null ? new LayoutStyle() : style;
		this.color = color;
		this.textStyle = textStyle;
		this.role = role == null ? TextRole.Body : role;
	}

	public function build(context:BuildContext):ViewRoot return makeNode(context);

	/** The text node itself, for a widget that composes text into a node of its own, as highlighted or shortened text does. */
	public function makeNode(context:BuildContext):RenderNode {
		var id = context.rootId("text");
		var identity = new StyleIdentity("text", null, null, null, ["text"]);
		var computed = context.resolveStyled(id, identity, style, null, color);
		var node = createNode(context, id, computed.toLayoutStyle());
		context.applyStyled(node, identity, computed);
		node.layout.text = value;
		var resolved = context.resolveTextRole(role, textStyle);
		var colorSource = computed.source(StyleProperty.TextColor);
		var fontSource = computed.source(StyleProperty.FontSize);
		var letterSource = computed.source(StyleProperty.LetterSpacing);
		var computedFontSize:Null<Float> = (textStyle == null || textStyle.fontSize == null)
			&& fontSource != null
			&& fontSource.layer != "framework" ? computed.getNumber(StyleProperty.FontSize) : null;
		var computedLetterSpacing:Null<Float> = (textStyle == null || textStyle.letterSpacing == null) && letterSource
			!= null && letterSource.layer != "framework" ? computed.getNumber(StyleProperty.LetterSpacing) : null;
		var computedColor:Null<Color> = color == null
			&& colorSource != null
			&& colorSource.layer != "framework" ? computed.getColor(StyleProperty.TextColor) : null;
		if (computedFontSize != null
			|| computedLetterSpacing != null
			|| computedColor != null) resolved = resolved.merge(new TextStyleOverride(null,
			computedFontSize,
			computedLetterSpacing,
			null,
			null,
			null,
			null,
			computedColor));
		if (color != null) resolved = resolved.withTextColor(color);
		node.applyTextStyle(resolved);
		node.semantics = new Semantics(AccessibilityRole.Text, value);
		return node;
	}

	function createNode(context:BuildContext, id:WidgetId, style:LayoutStyle):RenderNode return context.createNode(id,
		LayoutVisualKind.Text,
		style);
}
