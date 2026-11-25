package haxeon.ui;

/** Immutable two-dimensional point. */
class Point {
	/** Its horizontal coordinate. */
	public final x:Float;

	/** Its vertical coordinate. */
	public final y:Float;

	/** The point (`x`, `y`). */
	public function new(x:Float, y:Float) {
		this.x = x;
		this.y = y;
	}
}
