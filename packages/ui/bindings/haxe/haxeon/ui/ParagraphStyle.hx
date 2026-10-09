package haxeon.ui;

/** Semantic paragraph inputs shared by all NativeKit text APIs. */
class ParagraphStyle {
    public var wrap:TextWrap;
    public var alignment:TextAlignment;
    public var lineHeight:Null<Float>;
    public var direction:TextDirection;
    /** Tab stops in space advances; zero preserves the shaper default. */
    public var tabWidth:Int;

    public function new(wrap:TextWrap = TextWrap.WordCharacter,
            alignment:TextAlignment = TextAlignment.Start, lineHeight:Null<Float> = null,
            direction:TextDirection = TextDirection.Auto, tabWidth:Int = 0) {
        this.wrap = wrap;
        this.alignment = alignment;
        this.lineHeight = lineHeight;
        this.direction = direction;
        this.tabWidth = tabWidth;
    }
}
