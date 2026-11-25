package haxeon.ui;

import Hashable;

/** Immutable axis-aligned rectangle. */
struct Rect implements Hashable {
	/** Its left edge. */
	public final x:Float;

	/** Its top edge. */
	public final y:Float;

	/** Its width. */
	public final width:Float;

	/** Its height. */
	public final height:Float;

	/** A rectangle at (`x`, `y`) of `width` by `height`. */
	public function new(x:Float, y:Float, width:Float, height:Float) {
		this.x = x;
		this.y = y;
		this.width = width;
		this.height = height;
	}
}
