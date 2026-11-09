package haxeon.ui.core;

/** Platform-independent cursor intent for a render node. */
enum CursorShape implements Equatable {
	Arrow;
	Text;
	Crosshair;
	Hand;
	HorizontalResize;
	VerticalResize;
	/** Northwest-southeast diagonal resize. */
	DiagonalResize;
	Move;
	NotAllowed;
	/** Northeast-southwest diagonal resize. */
	DiagonalResizeNesw;
}
