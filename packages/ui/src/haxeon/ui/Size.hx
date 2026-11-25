package haxeon.ui;

/** Immutable two-dimensional size. */
class Size {
	/** The width. */
	public final width:Float;

	/** The height. */
	public final height:Float;

	/** A size of `width` by `height`. */
	public function new(width:Float, height:Float) {
		this.width = width;
		this.height = height;
	}
}
