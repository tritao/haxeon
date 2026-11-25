package haxeon.ui;

import Diffable;
import Hashable;

/** Immutable four-sided inset value. */
struct Insets implements Hashable implements Diffable {
	/** The left distance, in logical pixels. */
	public final left:Float;

	/** The top distance. */
	public final top:Float;

	/** The right distance. */
	public final right:Float;

	/** The bottom distance. */
	public final bottom:Float;

	/** Insets of the four distances. */
	public function new(left:Float, top:Float, right:Float, bottom:Float) {
		this.left = left;
		this.top = top;
		this.right = right;
		this.bottom = bottom;
	}
}
