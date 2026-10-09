package haxeon.audio;

import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** Configures the pitched oscillator component of a DSP patch. */
class DspOscillatorOptions {
	public var waveform:DspWaveform = DspWaveform.Sine;
	public var level:Float = 1.0;

	/** Optional immutable wavetable source; null selects the built-in waveform. */
	public var wavetable:DspWavetable = null;
	/** Relative tuning in cents; zero preserves the note frequency. */
	public var detuneCents:Float = 0.0;
	/** Initial and automatable normalized phase offset. */
	public var phase:Float = 0.0;

	public function new() {}

	@:allow(haxeon.audio.DspPatchBuilder)
	private function nativeValue():NativeDspOscillatorOptions {
		var result = new NativeDspOscillatorOptions();
		result.set_struct_size(NativeDspOscillatorOptions.size());
		result.set_waveform(waveform);
		result.set_level(level);
		result.set_wavetable(wavetable == null ? DspWavetableHandle.invalid() : wavetable.nativeHandle());
		result.set_detune_cents(detuneCents);
		result.set_phase(phase);
		return result;
	}
}
