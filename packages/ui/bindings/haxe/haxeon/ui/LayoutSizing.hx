package haxeon.ui;

/** Sizing policy for one layout axis. */
enum abstract LayoutSizing(Int) implements RawRepresentable {
	var Fit = 0;
	var Grow = 1;
	var Fixed = 2;
	var Percent = 3;
}
