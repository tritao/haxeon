package haxeon.ui.core;

import haxeon.ui.ParagraphStyle;
import haxeon.ui.TextStyle;

import haxeon.ui.Color;
import haxeon.ui.theme.Theme;
import haxeon.ui.theme.TextRoleStyle;

/** Concrete typography snapshot emitted onto a text-capable render node. */
class ResolvedTextStyle {
	public final textStyle:TextStyle;
	public final paragraphStyle:ParagraphStyle;
	public final textColor:Color;

	public function new(textStyle:TextStyle, paragraphStyle:ParagraphStyle, textColor:Color,
			?override:TextStyleOverride) {
		if (textStyle == null || paragraphStyle == null || textColor == null)
			throw "Resolved text styles require complete values";
		this.textStyle = new TextStyle(
			override == null || override.fontSize == null ? textStyle.fontSize : override.fontSize,
			override == null || override.font == null ? textStyle.font : override.font,
			override == null || override.letterSpacing == null ? textStyle.letterSpacing : override.letterSpacing);
		this.paragraphStyle = new ParagraphStyle(
			override == null || override.wrap == null ? paragraphStyle.wrap : override.wrap,
			override == null || override.alignment == null ? paragraphStyle.alignment : override.alignment,
			override == null || override.lineHeight == null ? paragraphStyle.lineHeight : override.lineHeight,
			override == null || override.direction == null ? paragraphStyle.direction : override.direction);
		this.textColor = override == null || override.color == null ? textColor : override.color;
	}

	public static function fromTheme(theme:Theme):ResolvedTextStyle {
		if (theme == null)
			throw "Resolved text styles require a theme";
		return fromRoleStyle(theme.body);
	}

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
		if (color == null)
			throw "Resolved text colors cannot be null";
		return new ResolvedTextStyle(textStyle, paragraphStyle, color);
	}

}
