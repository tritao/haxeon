package haxeon.audio;

/** Detuned copies of each oscillator/wavetable, sharing envelopes and modulation.
 * Gain is normalized by count. Specialized Daisy generators require count = 1.
 */
class DspUnisonOptions {
	/** How many copies sound. */
	public var count:Int = 1;

	/** How far apart they are tuned. */
	public var detuneCents:Float = 0;

	/** How widely they spread across the stereo field, from 0 to 1. */
	public var stereoSpread:Float = 0;

	/** A single voice. */
	public function new() {}
}
