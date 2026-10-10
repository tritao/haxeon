package haxeon.audio;

/** Detuned copies of each oscillator/wavetable, sharing envelopes and modulation.
 * Gain is normalized by count. Specialized Daisy generators require count = 1.
 */
class DspUnisonOptions {
	public var count:Int = 1;
	public var detuneCents:Float = 0;
	public var stereoSpread:Float = 0;
	public function new() {}
}
