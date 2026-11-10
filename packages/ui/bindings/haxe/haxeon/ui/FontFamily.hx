package haxeon.ui;

/** Font roles used by a FontCollection. */
enum abstract FontFamily(Int) implements RawRepresentable {
	var Default = 0;
	var Emoji = 1;
	var Monospace = 4;
}
