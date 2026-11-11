package haxeon.ui.widgets.controls;

/** Procedural visual used by Spinner. */
enum SpinnerKind implements Hashable {
	/** A rotating open arc. */
	Ring;
	/** Twelve dots with a moving highlight. */
	Dots;
	/** Twelve radial bars with a moving highlight. */
	Bars;
	/** Two expanding and fading circles. */
	Pulse;
}
