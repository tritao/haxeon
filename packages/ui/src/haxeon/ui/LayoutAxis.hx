package haxeon.ui;

import Diffable;
import Hashable;

/** One immutable axis policy encoded into a layout transaction. */
struct LayoutAxis implements Hashable implements Diffable {
	/** How the size is chosen: fit, grow, fixed or percent. */
	public final sizing:LayoutSizing;
	/** Exact value for FIXED, or the parent fraction for PERCENT. */
	public final value:Float;
	/** Minimum size for FIT/GROW. */
	public final min:Float;
	/** Maximum size for FIT/GROW; zero means unbounded. */
	public final max:Float;
	/** Relative share of extra space for GROW; ignored by other sizing modes. */
	public final growWeight:Float;

	function new(sizing:LayoutSizing = LayoutSizing.Fit, value:Float = 0.0,
			min:Float = 0.0, max:Float = 0.0, growWeight:Float = 1.0) {
		this.sizing = sizing;
		this.value = value;
		this.min = min;
		this.max = max;
		this.growWeight = growWeight;
	}

	/** The content's size, kept within `min` and `max` (0 for no maximum). */
	public static function fit(min:Float = 0.0, max:Float = 0.0):LayoutAxis
		return new LayoutAxis(LayoutSizing.Fit, 0.0, min, max);

	/** The space left over, shared by `growWeight` among growing siblings, within `min` and `max`. */
	public static function grow(min:Float = 0.0, max:Float = 0.0, growWeight:Float = 1.0):LayoutAxis
		return new LayoutAxis(LayoutSizing.Grow, 0.0, min, max, growWeight);

	/** Exactly `value` logical pixels. */
	public static function fixed(value:Float):LayoutAxis
		return new LayoutAxis(LayoutSizing.Fixed, value);

	/** `value` (0 to 1) of the parent's size. */
	public static function percent(value:Float):LayoutAxis
		return new LayoutAxis(LayoutSizing.Percent, value);

	/** Fills the parent's available size on this axis without consuming main-axis grow space. */
	public static function stretch():LayoutAxis
		return percent(1.0);
}

/** Sizing policy for one layout axis. */
typedef LayoutSizing = NativeKitUI.UiLayoutSizing;
