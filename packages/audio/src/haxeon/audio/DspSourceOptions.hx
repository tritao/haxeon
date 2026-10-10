package haxeon.audio;
import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;
/** Typed source configuration, copied when a patch is built. Controls are immutable per patch. */
class DspSourceOptions {
  public final kind:DspSourceKind;
  public var samples:Array<Float> = [];
  final options:NativeDspSourceOptions;
  public function new(kind:DspSourceKind) {
    this.kind = kind;
    var made = NativeKitAudio.nk_audio_dsp_source_defaults(cast kind);
    AudioResult.check(made.status, "audio.dsp.source.defaults");
    options = made.out_options;
  }
  public function set(parameter:DspSourceParameter, value:Float):DspSourceOptions {
    var domain = NativeKitAudio.nk_audio_dsp_source_parameter_info(cast kind, cast parameter);
    AudioResult.check(domain.status, "audio.dsp.source.parameter");
    if (!Math.isFinite(value)
      || value < domain.out_minimum || value > domain.out_maximum) throw "DSP source parameter is out of range";
    if ((parameter == DspSourceParameter.Resolution
      || parameter == DspSourceParameter.FirstHarmonic || parameter == DspSourceParameter.RootNote
      || parameter == DspSourceParameter.Sustain || parameter == DspSourceParameter.SyncEnabled)
      && value != Math.floor(value)) throw "DSP source parameter requires an integer";
    if (parameter == DspSourceParameter.Resolution
      && value % 4 != 0) throw "Resonator resolution requires groups of four modes";
    options.set_values((parameter:Int), value);
    return this;
  }
  public function get(parameter:DspSourceParameter):Float {
    var domain = NativeKitAudio.nk_audio_dsp_source_parameter_info(cast kind, cast parameter);
    AudioResult.check(domain.status, "audio.dsp.source.parameter");
    return options.get_values((parameter:Int));
  }
  /** Bank: seven registrations; Harmonic: sixteen partials. Normalize nonnegative weights. */
  public function spectrum(weights:Array<Float>):DspSourceOptions {
    var count = kind == DspSourceKind.OscillatorBank ? 7 : kind == DspSourceKind.Harmonic ? 16 : 0;
    if (count == 0 || weights == null || weights.length != count) throw "Invalid source spectrum length";
    var total:Float = 0;
    for (weight in weights) {
      if (!Math.isFinite(weight) || weight < 0) throw "Invalid source spectrum weight";
      total += weight;
    }
    if (!Math.isFinite(total) || total <= 0) throw "Source spectrum must contain positive weight";
    for (i in 0...count) options.set_amplitudes(i, weights[i] / total);
    return this;
  }
  @:allow(haxeon.audio.DspPatchBuilder) private function nativeValue():NativeDspSourceOptions return options;
}
