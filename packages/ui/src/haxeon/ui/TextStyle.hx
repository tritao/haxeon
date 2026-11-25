package haxeon.ui;

import Hashable;
import NativeKitUI;
import haxeon.ui.FontCollection;

/** Semantic font and inline-spacing inputs shared by all NativeKit text APIs. */
struct TextStyle implements Hashable {
	/** The font family. */
	public final font:FontFamily;
	/** The size, in logical pixels. */
	public final fontSize:Float;
	/** Extra space between letters, in logical pixels. */
	public final letterSpacing:Float;

	/** A text style. */
	public function new(fontSize:Float = 16.0, font:FontFamily = FontFamily.Default,
			letterSpacing:Float = 0.0) {
		if (fontSize <= 0.0 || Math.isNaN(fontSize) || Math.isNaN(letterSpacing))
			throw "Text style values are invalid";
		this.font = font;
		this.fontSize = fontSize;
		this.letterSpacing = letterSpacing;
	}

	/** A copy with `fontSize` set to `value`. */
	public function withFontSize(value:Float):TextStyle
		return new TextStyle(value, font, letterSpacing);

	/** A copy with `letterSpacing` set to `value`. */
	public function withLetterSpacing(value:Float):TextStyle
		return new TextStyle(fontSize, font, value);
}

/** Semantic paragraph inputs shared by all NativeKit text APIs. */
struct ParagraphStyle implements Hashable {
	/** How lines break. */
	public final wrap:TextWrap;
	/** How lines align. */
	public final alignment:TextAlignment;
	/** The distance between baselines, in logical pixels; the font's when null. */
	public final lineHeight:Null<Float>;
	/** The base text direction. */
	public final direction:TextDirection;
	/** Tab stops in space advances; zero preserves the shaper default. */
	public final tabWidth:Int;

	/** A paragraph style. */
	public function new(wrap:TextWrap = TextWrap.WordCharacter,
			alignment:TextAlignment = TextAlignment.Start, lineHeight:Null<Float> = null,
			direction:TextDirection = TextDirection.Auto, tabWidth:Int = 0) {
		this.wrap = wrap;
		this.alignment = alignment;
		this.lineHeight = lineHeight;
		this.direction = direction;
		this.tabWidth = tabWidth;
	}

	/** A copy with `wrap` set to `value`. */
	public function withWrap(value:TextWrap):ParagraphStyle
		return new ParagraphStyle(value, alignment, lineHeight, direction, tabWidth);

	/** A copy with `alignment` set to `value`. */
	public function withAlignment(value:TextAlignment):ParagraphStyle
		return new ParagraphStyle(wrap, value, lineHeight, direction, tabWidth);

	/** A copy with `lineHeight` set to `value`. */
	public function withLineHeight(value:Null<Float>):ParagraphStyle
		return new ParagraphStyle(wrap, alignment, value, direction, tabWidth);

	/** A copy with `direction` set to `value`. */
	public function withDirection(value:TextDirection):ParagraphStyle
		return new ParagraphStyle(wrap, alignment, lineHeight, value, tabWidth);

	/** A copy with the tab width set to `value` spaces. */
	public function withTabWidth(value:Int):ParagraphStyle
		return new ParagraphStyle(wrap, alignment, lineHeight, direction, value);
}

/** Immutable half-open codepoint range overriding a retained layout's foreground. */
class TextColorRange {
	/** The first character colored. */
	public final start:Int;
	/** The character after the last. */
	public final end:Int;
	/** Their color. */
	public final color:Color;

	/** Colors the characters from `start` to `end`. */
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
