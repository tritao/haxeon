package haxeon.audio;

/** Minimum and maximum distances used by spatial attenuation. */
class DistanceLimits {
	/** The distance within which there is no attenuation. */
	public final min:Float;

	/** The distance beyond which attenuation stops growing. */
	public final max:Float;

	/** Limits from `min` to `max`. */
	public function new(min:Float, max:Float) {
		this.min = min;
		this.max = max;
	}
}
