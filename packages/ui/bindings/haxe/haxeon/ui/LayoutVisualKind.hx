package haxeon.ui;

/** Rendering/layout representation, independent from semantic role. */
enum LayoutVisualKind implements Hashable {
	Box;
	Text;
	Image;
	Custom;
}
