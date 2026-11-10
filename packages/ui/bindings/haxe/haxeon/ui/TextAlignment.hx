package haxeon.ui;

/** Horizontal alignment of paragraph lines. */
enum abstract TextAlignment(Int) implements RawRepresentable {
	var Start = 0;
	var Center = 1;
	var End = 2;
}
