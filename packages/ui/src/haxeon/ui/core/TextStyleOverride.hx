package haxeon.ui.core;

import haxeon.ui.Color;
import haxeon.ui.FontCollection;
import haxeon.ui.TextStyle;
import haxeon.ui.theme.TextRole;
import haxeon.ui.theme.Theme;

/**
 * Sparse typography changes applied to the current inherited text style.
 *
 * Null means inherit. A line height of zero is an explicit request for the
 * paragraph engine's automatic line height; it is therefore distinct from a
 * null lineHeight.
 */
class TextStyleOverride {
	/** The font family; null inherits it. */
	public final font:Null<FontFamily>;

	/** The size in logical pixels; null inherits it. */
	public final fontSize:Null<Float>;

	/** Extra space between letters, in logical pixels; null inherits it. */
	public final letterSpacing:Null<Float>;

	/** How lines wrap; null inherits it. */
	public final wrap:Null<TextWrap>;

	/** How lines align; null inherits it. */
	public final alignment:Null<TextAlignment>;

	/** The line height as a multiple of the font size, 0 for the font's own; null inherits it. */
	public final lineHeight:Null<Float>;

	/** Left to right or right to left; null inherits it. */
	public final direction:Null<TextDirection>;

	/** The text color; null inherits it. */
	public final color:Null<Color>;

	/** How many spaces a tab spans; null inherits it. */
	public final tabWidth:Null<Int>;

	/**
	 * Changes to the inherited text style; each argument left out is inherited. `text`, `paragraph` and `foreground`
	 * make the common ones.
	 */
	public function new(?font:FontFamily, ?fontSize:Float, ?letterSpacing:Float,
			?wrap:TextWrap, ?alignment:TextAlignment, ?lineHeight:Float,
			?direction:TextDirection, ?color:Color, ?tabWidth:Int) {
		if (fontSize != null && (!finite(fontSize) || fontSize <= 0.0))
			throw "Text style override font size is invalid";
		if (letterSpacing != null && !finite(letterSpacing))
			throw "Text style override letter spacing is invalid";
		if (lineHeight != null && (!finite(lineHeight) || lineHeight < 0.0))
			throw "Text style override line height is invalid";
		this.font = font;
		this.fontSize = fontSize;
		this.letterSpacing = letterSpacing;
		this.wrap = wrap;
		this.alignment = alignment;
		this.lineHeight = lineHeight;
		this.direction = direction;
		this.color = color;
		if (tabWidth != null && tabWidth < 0) throw "Tab width cannot be negative";
		this.tabWidth = tabWidth;
	}

	/** Creates a text-only override without positional null placeholders. */
	public static function text(?fontSize:Float, ?letterSpacing:Float,
			?color:Color, ?font:FontFamily):TextStyleOverride
		return new TextStyleOverride(font, fontSize, letterSpacing, null, null, null, null, color);

	/** Creates a paragraph-only override without positional null placeholders. */
	public static function paragraph(?wrap:TextWrap, ?alignment:TextAlignment,
			?lineHeight:Float, ?direction:TextDirection, ?tabWidth:Int):TextStyleOverride
		return new TextStyleOverride(null, null, null, wrap, alignment, lineHeight, direction, null, tabWidth);

	/** Creates a foreground-only override. */
	public static function foreground(color:Color):TextStyleOverride
		return new TextStyleOverride(null, null, null, null, null, null, null, color);

	/** Combines a parent override with a child override; child fields win. */
	public static function combine(parent:Null<TextStyleOverride>,
			child:Null<TextStyleOverride>):Null<TextStyleOverride> {
		if (parent == null)
			return child;
		if (child == null)
			return parent;
		return new TextStyleOverride(child.font == null ? parent.font : child.font,
			child.fontSize == null ? parent.fontSize : child.fontSize,
			child.letterSpacing == null ? parent.letterSpacing : child.letterSpacing,
			child.wrap == null ? parent.wrap : child.wrap,
			child.alignment == null ? parent.alignment : child.alignment,
			child.lineHeight == null ? parent.lineHeight : child.lineHeight,
			child.direction == null ? parent.direction : child.direction,
			child.color == null ? parent.color : child.color,
			child.tabWidth == null ? parent.tabWidth : child.tabWidth);
	}

	/** Turns a complete text style into a local override. */
	public static function fromTextStyle(style:Null<TextStyle>):Null<TextStyleOverride> {
		if (style == null)
			return null;
		return new TextStyleOverride(style.font, style.fontSize, style.letterSpacing);
	}

	/** Turns a complete paragraph style into a local override. */
	public static function fromParagraphStyle(style:Null<ParagraphStyle>):Null<TextStyleOverride> {
		if (style == null)
			return null;
		return new TextStyleOverride(null, null, null, style.wrap, style.alignment,
			style.lineHeight == null ? 0.0 : style.lineHeight, style.direction, null, style.tabWidth);
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}

/** Concrete typography snapshot emitted onto a text-capable render node. */
class ResolvedTextStyle {
	/** The font, size and spacing. */
	public final textStyle:TextStyle;

	/** Wrapping, alignment, line height, direction and tab width. */
	public final paragraphStyle:ParagraphStyle;

	/** The color text is drawn in. */
	public final textColor:Color;

	/** A complete text style. */
	public function new(textStyle:TextStyle, paragraphStyle:ParagraphStyle, textColor:Color,
			?override:TextStyleOverride) {
		if (textStyle == null || paragraphStyle == null)
			throw "Resolved text styles require complete values";
		this.textStyle = new TextStyle(override == null
			|| override.fontSize == null ? textStyle.fontSize : override.fontSize,
			override == null || override.font == null ? textStyle.font : override.font,
			override == null || override.letterSpacing == null ? textStyle.letterSpacing : override.letterSpacing);
		this.paragraphStyle = new ParagraphStyle(override == null
			|| override.wrap == null ? paragraphStyle.wrap : override.wrap,
			override == null || override.alignment == null ? paragraphStyle.alignment : override.alignment,
			override == null || override.lineHeight == null ? paragraphStyle.lineHeight : override.lineHeight,
			override == null || override.direction == null ? paragraphStyle.direction : override.direction,
			override == null || override.tabWidth == null ? paragraphStyle.tabWidth : override.tabWidth);
		this.textColor = override == null || override.color == null ? textColor : override.color;
	}

	/** The theme's body text style. */
	public static function fromTheme(theme:Theme):ResolvedTextStyle {
		if (theme == null)
			throw "Resolved text styles require a theme";
		return fromRoleStyle(theme.body);
	}

	/** The style of a theme text role, such as a heading or a caption. */
	public static function fromRoleStyle(role:TextRoleStyle):ResolvedTextStyle {
		if (role == null)
			throw "Resolved text styles require a role";
		return new ResolvedTextStyle(role.textStyle, role.paragraphStyle, role.color);
	}

	/** Applies sparse local changes without mutating either input style. */
	public function merge(override:Null<TextStyleOverride>):ResolvedTextStyle
		return new ResolvedTextStyle(textStyle, paragraphStyle, textColor, override);

	/** Returns this snapshot with a state-dependent foreground color. */
	public function withTextColor(color:Color):ResolvedTextStyle {
		return new ResolvedTextStyle(textStyle, paragraphStyle, color);
	}

}
