package haxeon.ui;

import Hashable;
import haxeon.ui.FontFamily;

/** Semantic font and inline-spacing inputs shared by all NativeKit text APIs. */
struct TextStyle : Hashable {
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
