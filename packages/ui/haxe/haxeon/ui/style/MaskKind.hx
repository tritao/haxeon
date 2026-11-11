package haxeon.ui.style;

/** Typed source-alpha mask families understood by the native compositor. */
enum MaskKind implements Hashable {
	Rectangle;
	RoundedRect;
	Circle;
	LinearGradient;
	Image;
}
