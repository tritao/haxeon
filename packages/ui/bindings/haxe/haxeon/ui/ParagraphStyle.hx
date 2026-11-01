package haxeon.ui;

import Hashable;
/** Semantic paragraph inputs shared by all NativeKit text APIs. */
struct ParagraphStyle : Hashable {
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
