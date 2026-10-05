package haxeon.ui;

import NativeKitUI;

/** Immutable half-open codepoint range overriding a retained layout's foreground. */
class TextColorRange {
	public final start:Int;
	public final end:Int;
	public final color:Color;

	public function new(start:Int, end:Int, color:Color) {
		if (start < 0 || end <= start || color == null)
			throw "Text color ranges require a nonempty range and color";
		this.start = start;
		this.end = end;
		this.color = color;
	}

	@:allow(TextLayout)
	private function nativeValue():nkui_text_color_range {
		var result = new nkui_text_color_range();
		result.set_start(start);
		result.set_end(end);
		result.set_color(color.nativeValue());
		return result;
	}
}
