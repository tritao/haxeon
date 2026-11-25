package haxeon.ui.style;

/** How much room controls take: Pointer suits a mouse, Touch suits fingers. */
enum abstract Density(Int) {
	/** Sized for a mouse or trackpad. */
	var Pointer = 0;
	/** Sized for fingers: larger rows and targets. */
	var Touch = 1;
}
