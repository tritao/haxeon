package haxeon.ui.core;

/** Work categories used by the style/layout invalidation boundary. */
enum abstract UiDirtyFlag(Int) implements Flags {
	/** No work is pending. */
	var None = 0;

	/** Views must be built again. */
	var NeedsBuild = 1 << 0;

	/** Computed styles must be resolved again. */
	var NeedsStyle = 1 << 1;

	/** Text must be shaped again. */
	var NeedsTextLayout = 1 << 2;

	/** Sizes and positions must be computed again. */
	var NeedsLayout = 1 << 3;

	/** The UI must be drawn again. */
	var NeedsPaint = 1 << 4;

	/** Layers must be composited again. */
	var NeedsComposite = 1 << 5;

	/** What assistive technology is told must be updated. */
	var NeedsSemantics = 1 << 6;
	/** Resolved transforms, clips, bounds, or paint order must be refreshed. */
	var NeedsHitGeometry = 1 << 7;

	/** Work that changes a serialized native node; build/child membership is compared separately. */
	var NativeInputs = NeedsTextLayout | NeedsLayout | NeedsPaint | NeedsComposite | NeedsHitGeometry;
}
