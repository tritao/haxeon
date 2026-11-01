package haxeon.ui.style;

import Hashable;

/**
 * Extra paint extent requested by a visual effect, in logical pixels.
 *
 * This is deliberately a value type. It describes the geometry contract
 * between style and rendering without exposing render targets or GPU state to
 * the Haxe style system.
 */
struct InkOverflow : Hashable {
	public final left:Float;
	public final top:Float;
	public final right:Float;
	public final bottom:Float;

	public function new(left:Float = 0.0, top:Float = 0.0, right:Float = 0.0,
			bottom:Float = 0.0) {
		if (!Math.isFinite(left) || left < 0.0 || !Math.isFinite(top) || top < 0.0 ||
			!Math.isFinite(right) || right < 0.0 || !Math.isFinite(bottom) || bottom < 0.0)
			throw "Effect ink overflow must be finite and non-negative";
		this.left = left;
		this.top = top;
		this.right = right;
		this.bottom = bottom;
	}

	public static function zero():InkOverflow
		return new InkOverflow();

	/** Adds sequential effect extents. */
	public function added(other:Null<InkOverflow>):InkOverflow {
		if (other == null)
			return this;
		return new InkOverflow(left + other.left, top + other.top,
			right + other.right, bottom + other.bottom);
	}


	public function toString():String
		return '($left, $top, $right, $bottom)';
}
