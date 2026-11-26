package haxeon.audio;

/** Per-patch articulation settings. Mono/legato/glide support ordinary oscillators and
 * wavetables. Held notes use bounded last-note priority; accent is driven by note velocity.
 */
class DspArticulationOptions {
	/** Whether only one note sounds at a time. */
	public var monophonic:Bool = false;

	/** Whether a monophonic note played over another glides instead of retriggering. */
	public var legato:Bool = false;

	/** How long a legato glide takes. */
	public var glideSeconds:Float = 0;

	/** Extra gain for accented notes. */
	public var accentGain:Float = 0;

	/** How far an accent opens the filter, in semitones. */
	public var accentFilterSemitones:Float = 0;

	/** The velocity from which a note is accented. */
	public var accentVelocityThreshold:Float = 0.8;

	/** Plain polyphonic articulation. */
	public function new() {}
}
