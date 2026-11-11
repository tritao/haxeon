package haxeon.ui.widgets;

/** Controls how an image's intrinsic aspect ratio maps into its view bounds. */
enum ImageFit implements Hashable {
	Stretch;
	Contain;
	Cover;
	None;
}
