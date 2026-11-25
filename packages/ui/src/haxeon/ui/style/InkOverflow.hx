package haxeon.ui.style;

import Hashable;

/**
 * Extra paint extent requested by a visual effect, in logical pixels.
 *
 * This is deliberately a value type. It describes the geometry contract
 * between style and rendering without exposing render targets or GPU state to
 * the Haxe style system.
 */
struct InkOverflow implements Hashable {
	/** How far drawing may reach past the left edge. */
	public final left:Float;

	/** How far past the top edge. */
	public final top:Float;

	/** How far past the right edge. */
	public final right:Float;

	/** How far past the bottom edge. */
	public final bottom:Float;

	/** Overflow of the given distances. Throws when one is negative or not finite. */
	public function new(left:Float = 0.0, top:Float = 0.0, right:Float = 0.0,
			bottom:Float = 0.0) {
		if (!Math.isFinite(left) || left < 0.0 || !Math.isFinite(top) || top < 0.0 || !Math.isFinite(right)
			|| right < 0.0 || !Math.isFinite(bottom) || bottom < 0.0)
			throw "VisualEffect ink overflow must be finite and non-negative";
		this.left = left;
		this.top = top;
		this.right = right;
		this.bottom = bottom;
	}

	/** No overflow. */
	public static function zero():InkOverflow
		return new InkOverflow();

	/** Adds sequential effect extents. */
	public function added(other:Null<InkOverflow>):InkOverflow {
		if (other == null)
			return this;
		return new InkOverflow(left + other.left, top + other.top,
			right + other.right, bottom + other.bottom);
	}


	/** A description for inspection. */
	public function toString():String
		return '($left, $top, $right, $bottom)';
}
