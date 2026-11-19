package haxeon.ui.style;

import haxeon.ui.style.Density;

/** Sizes that depend on Density. Obtain them with `DensityTokens.of(context.density)`. */
class DensityTokens {
	static final pointer:DensityTokens = new DensityTokens(28.0, 28.0, 16.0, 1.0);
	static final touch:DensityTokens = new DensityTokens(56.0, 44.0, 16.0, 1.0);

	/** Minimum height of a list or tree row. */
	public final rowHeight:Float;
	/** Minimum size of anything that can be pressed. */
	public final touchTarget:Float;
	/** Horizontal indentation per hierarchy level. */
	public final indent:Float;
	/** Multiplier for text sizes. */
	public final fontScale:Float;

	function new(rowHeight:Float, touchTarget:Float, indent:Float, fontScale:Float) {
		this.rowHeight = rowHeight;
		this.touchTarget = touchTarget;
		this.indent = indent;
		this.fontScale = fontScale;
	}

	public static function of(density:Density):DensityTokens
		return density == Density.Touch ? touch : pointer;
}
