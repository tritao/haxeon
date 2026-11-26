package haxeon.audio;

/** Minimum and maximum gain applied by spatialization. */
class GainLimits {
	/** The lowest gain. */
	public final min:Float;

	/** The highest gain. */
	public final max:Float;

	/** Limits from `min` to `max`. */
	public function new(min:Float, max:Float) {
		this.min = min;
		this.max = max;
	}
}
