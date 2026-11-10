package haxeon.ui;

/** Base direction requested for a paragraph. */
enum abstract TextDirection(Int) implements RawRepresentable {
	var Auto = 0;
	var Ltr = 1;
	var Rtl = 2;
}
