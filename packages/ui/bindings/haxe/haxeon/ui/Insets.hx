package haxeon.ui;

import Diffable;
import Hashable;

/** Immutable four-sided inset value. */
struct Insets implements Hashable implements Diffable {
	public final left:Float;
	public final top:Float;
	public final right:Float;
	public final bottom:Float;

	public function new(left:Float, top:Float, right:Float, bottom:Float) {
		this.left = left;
		this.top = top;
		this.right = right;
		this.bottom = bottom;
	}
}
