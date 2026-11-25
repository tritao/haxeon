package haxeon.ui.style;

/** How much room controls take: Pointer suits a mouse, Touch suits fingers. */
enum abstract Density(Int) {
	var Pointer = 0;
	var Touch = 1;
}
