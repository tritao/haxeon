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

	static final defaultFit = new LayoutAxis(LayoutSizing.Fit);
	static final defaultGrow = new LayoutAxis(LayoutSizing.Grow);

	public static function fit(min:Float = 0.0, max:Float = 0.0):LayoutAxis
		return min == 0.0 && max == 0.0 ? defaultFit : new LayoutAxis(LayoutSizing.Fit, 0.0, min, max);

	public static function grow(min:Float = 0.0, max:Float = 0.0, growWeight:Float = 1.0):LayoutAxis
		return min == 0.0 && max == 0.0 && growWeight == 1.0 ? defaultGrow : new LayoutAxis(LayoutSizing.Grow, 0.0, min, max, growWeight);

	public static function fixed(value:Float):LayoutAxis
		return new LayoutAxis(LayoutSizing.Fixed, value);

	public static function percent(value:Float):LayoutAxis
		return new LayoutAxis(LayoutSizing.Percent, value);

	/** Fills the parent's available size on this axis without consuming main-axis grow space. */
	public static function stretch():LayoutAxis
		return percent(1.0);
}
