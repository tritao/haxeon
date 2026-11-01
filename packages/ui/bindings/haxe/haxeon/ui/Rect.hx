package haxeon.ui;

import Hashable;

/** Immutable axis-aligned rectangle. */
struct Rect : Hashable {
	public final x:Float;
	public final y:Float;
	public final width:Float;
	public final height:Float;

	public function new(x:Float, y:Float, width:Float, height:Float) {
		this.x = x;
		this.y = y;
		this.width = width;
		this.height = height;
	}
}
