package haxeon.ui.layout;

/** The size text takes, as `LayoutSession.measureText` measures it; reused between calls. */
class TextMeasure {
	/** Unwrapped: the advance rounded up to a whole pixel. At a width: that width. */
	public var width:Float = 0.0;

	/** The paragraph's line height when it sets one, else the text's height. */
	public var height:Float = 0.0;

	/** The first line's baseline from the top, when `hasBaseline`. */
	public var baseline:Float = 0.0;

	public var hasBaseline:Bool = false;

	public function new() {}
}
