package haxeon.ui.style;

/** Typed decoration families understood by the style and paint systems. */
enum DecorationKind implements Equatable {
	Background;
	Gradient;
	Image;
	NineSlice;
	Border;
	Outline;
	Shadow;
	/** A user-defined renderer-owned decoration. */
	Custom;
}
