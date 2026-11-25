package haxeon.ui;

import Hashable;
import NativeKitUI;
import haxeon.ui.FontCollection;

/** Semantic font and inline-spacing inputs shared by all NativeKit text APIs. */
struct TextStyle implements Hashable {
	public final font:FontFamily;
	public final fontSize:Float;
	public final letterSpacing:Float;

	public function new(fontSize:Float = 16.0, font:FontFamily = FontFamily.Default,
			letterSpacing:Float = 0.0) {
		if (fontSize <= 0.0 || Math.isNaN(fontSize) || Math.isNaN(letterSpacing))
			throw "Text style values are invalid";
		this.font = font;
		this.fontSize = fontSize;
		this.letterSpacing = letterSpacing;
	}

	public function withFontSize(value:Float):TextStyle
		return new TextStyle(value, font, letterSpacing);

	public function withLetterSpacing(value:Float):TextStyle
		return new TextStyle(fontSize, font, value);
}

/** Semantic paragraph inputs shared by all NativeKit text APIs. */
struct ParagraphStyle implements Hashable {
	public final wrap:TextWrap;
	public final alignment:TextAlignment;
	public final lineHeight:Null<Float>;
	public final direction:TextDirection;
	/** Tab stops in space advances; zero preserves the shaper default. */
	public final tabWidth:Int;

	public function new(wrap:TextWrap = TextWrap.WordCharacter,
			alignment:TextAlignment = TextAlignment.Start, lineHeight:Null<Float> = null,
			direction:TextDirection = TextDirection.Auto, tabWidth:Int = 0) {
		this.wrap = wrap;
		this.alignment = alignment;
		this.lineHeight = lineHeight;
		this.direction = direction;
		this.tabWidth = tabWidth;
	}

	public function withWrap(value:TextWrap):ParagraphStyle
		return new ParagraphStyle(value, alignment, lineHeight, direction, tabWidth);

	public function withAlignment(value:TextAlignment):ParagraphStyle
		return new ParagraphStyle(wrap, value, lineHeight, direction, tabWidth);

	public function withLineHeight(value:Null<Float>):ParagraphStyle
		return new ParagraphStyle(wrap, alignment, value, direction, tabWidth);

	public function withDirection(value:TextDirection):ParagraphStyle
		return new ParagraphStyle(wrap, alignment, lineHeight, value, tabWidth);

	public function withTabWidth(value:Int):ParagraphStyle
		return new ParagraphStyle(wrap, alignment, lineHeight, direction, value);
}

/** Immutable half-open codepoint range overriding a retained layout's foreground. */
class TextColorRange {
	public final start:Int;
	public final end:Int;
	public final color:Color;

	public function new(start:Int, end:Int, color:Color) {
		if (start < 0 || end <= start)
			throw "Text color ranges require a nonempty range";
		this.start = start;
		this.end = end;
		this.color = color;
	}

	@:allow(haxeon.ui.TextLayout)
	private function nativeValue():nkui_text_color_range {
		var result = new nkui_text_color_range();
		result.set_start(start);
		result.set_end(end);
		result.set_color(color.nativeValue());
		return result;
	}
}

/** Horizontal alignment of paragraph lines. */
typedef TextAlignment = NativeKitUI.UiTextAlignment;

/** Base direction requested for a paragraph. */
typedef TextDirection = NativeKitUI.UiTextDirection;

/** Paragraph line-breaking policy. */
typedef TextWrap = NativeKitUI.UiTextWrap;
