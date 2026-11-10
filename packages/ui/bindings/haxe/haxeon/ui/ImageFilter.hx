package haxeon.ui;

/** Texture sampling used when an image is drawn larger or smaller than its source. */
enum ImageFilter implements Hashable {
	Linear;
	Nearest;
}
