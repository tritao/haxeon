package haxeon.ui;

/** One Haxe-owned axis policy encoded into a layout transaction. Immutable, so styles and copies share instances. */
class LayoutAxis {
	public final sizing:LayoutSizing;
	/** Exact value for FIXED, or the parent fraction for PERCENT. */
	public final value:Float;
	/** Minimum size for FIT/GROW. */
	public final min:Float;
	/** Maximum size for FIT/GROW; zero means unbounded. */
	public final max:Float;
	/** Relative share of extra space for GROW; ignored by other sizing modes. */
	public final growWeight:Float;

	public function new(sizing:LayoutSizing = LayoutSizing.Fit, value:Float = 0.0,
			min:Float = 0.0, max:Float = 0.0, growWeight:Float = 1.0) {
		this.sizing = sizing;
		this.value = value;
		this.min = min;
		this.max = max;
		this.growWeight = growWeight;
	}

	// Themes can construct styles during module initialization. Lazy immutable
	// defaults prevent those early styles from retaining null axis policies.
	static var defaultFit:Null<LayoutAxis>;
	static var defaultGrow:Null<LayoutAxis>;

	public static function fit(min:Float = 0.0, max:Float = 0.0):LayoutAxis {
		if (min != 0.0 || max != 0.0) return new LayoutAxis(LayoutSizing.Fit, 0.0, min, max);
		if (defaultFit == null) defaultFit = new LayoutAxis(LayoutSizing.Fit);
		return cast defaultFit;
	}

	public static function grow(min:Float = 0.0, max:Float = 0.0, growWeight:Float = 1.0):LayoutAxis {
		if (min != 0.0 || max != 0.0 || growWeight != 1.0)
			return new LayoutAxis(LayoutSizing.Grow, 0.0, min, max, growWeight);
		if (defaultGrow == null) defaultGrow = new LayoutAxis(LayoutSizing.Grow);
		return cast defaultGrow;
	}

	public static function fixed(value:Float):LayoutAxis
		return new LayoutAxis(LayoutSizing.Fixed, value);

	public static function percent(value:Float):LayoutAxis
		return new LayoutAxis(LayoutSizing.Percent, value);

	/** Fills the parent's available size on this axis without consuming main-axis grow space. */
	public static function stretch():LayoutAxis
		return percent(1.0);
}
