package haxeon.ui.core;

/** Work categories used by the style/layout invalidation boundary. */
enum abstract UiDirtyFlag(Int) implements Flags {
	var None = 0;
	var NeedsBuild = 1 << 0;
	var NeedsStyle = 1 << 1;
	var NeedsTextLayout = 1 << 2;
	var NeedsLayout = 1 << 3;
	var NeedsPaint = 1 << 4;
	var NeedsComposite = 1 << 5;
	var NeedsSemantics = 1 << 6;
	/** Resolved transforms, clips, bounds, or paint order must be refreshed. */
	var NeedsHitGeometry = 1 << 7;

	/** Work that changes a serialized native node; build/child membership is compared separately. */
	var NativeInputs = NeedsTextLayout | NeedsLayout | NeedsPaint | NeedsComposite | NeedsHitGeometry;
}
