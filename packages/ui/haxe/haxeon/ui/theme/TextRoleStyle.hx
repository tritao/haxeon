package haxeon.ui.theme;

import haxeon.ui.widgets.text.Text;


import haxeon.ui.Color;
import haxeon.ui.FontFamily;
import haxeon.ui.ParagraphStyle;
import haxeon.ui.TextAlignment;
import haxeon.ui.TextDirection;
import haxeon.ui.TextStyle;
import haxeon.ui.TextWrap;
import haxeon.ui.core.TextStyleOverride;

/** Complete concrete typography and color definition for one semantic role. */
class TextRoleStyle {
	public var textStyle:TextStyle;
	public var paragraphStyle:ParagraphStyle;
	public var color:Color;

	public function new(textStyle:TextStyle, paragraphStyle:ParagraphStyle, color:Color) {
		if (textStyle == null || paragraphStyle == null || color == null)
			throw "Text role styles require complete values";
		this.textStyle = textStyle;
		this.paragraphStyle = paragraphStyle;
		this.color = color;
	}

	// The override is immutable and a role changes only when a theme edits it, so the last one is kept with the values it was
	// built from and reused while they still match.
	var cached:Null<TextStyleOverride> = null;
	var cachedFont:FontFamily;
	var cachedSize:Float;
	var cachedSpacing:Float;
	var cachedWrap:TextWrap;
	var cachedAlignment:TextAlignment;
	var cachedLineHeight:Float;
	var cachedDirection:TextDirection;
	var cachedColor:Null<Color>;
	var cachedTabWidth:Int;

	/** Converts this complete role into a sparse style usable in a nested scope. */
	public function toOverride():TextStyleOverride {
		var lineHeight = paragraphStyle.lineHeight == null ? 0.0 : paragraphStyle.lineHeight;
		var reusable = cached;
		if (reusable != null && cachedFont == textStyle.font && cachedSize == textStyle.fontSize
			&& cachedSpacing == textStyle.letterSpacing && cachedWrap == paragraphStyle.wrap
			&& cachedAlignment == paragraphStyle.alignment && cachedLineHeight == lineHeight
			&& cachedDirection == paragraphStyle.direction && cachedColor == color
			&& cachedTabWidth == paragraphStyle.tabWidth)
			return reusable;
		var next = new TextStyleOverride(textStyle.font, textStyle.fontSize,
			textStyle.letterSpacing, paragraphStyle.wrap, paragraphStyle.alignment, lineHeight,
			paragraphStyle.direction, color, paragraphStyle.tabWidth);
		cached = next;
		cachedFont = textStyle.font;
		cachedSize = textStyle.fontSize;
		cachedSpacing = textStyle.letterSpacing;
		cachedWrap = paragraphStyle.wrap;
		cachedAlignment = paragraphStyle.alignment;
		cachedLineHeight = lineHeight;
		cachedDirection = paragraphStyle.direction;
		cachedColor = color;
		cachedTabWidth = paragraphStyle.tabWidth;
		return next;
	}
}
