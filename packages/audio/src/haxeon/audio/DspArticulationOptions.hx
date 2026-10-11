package haxeon.audio;

/** Per-patch articulation settings. Mono/legato/glide support ordinary oscillators and
 * wavetables. Held notes use bounded last-note priority; accent is driven by note velocity.
 */
class DspArticulationOptions {
  public var monophonic:Bool=false;
  public var legato:Bool=false;
  public var glideSeconds:Float=0;
  public var accentGain:Float=0;
  public var accentFilterSemitones:Float=0;
  public var accentVelocityThreshold:Float=0.8;
  public function new() {}
}
