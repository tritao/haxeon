package haxeon.audio;

import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** Configures the pitched oscillator component of a DSP patch. */
class DspOscillatorOptions {
	/** Its wave shape. */
	public var waveform:DspWaveform = DspWaveform.Sine;

	/** Its level, from 0. */
	public var level:Float = 1.0;

	/** Optional immutable wavetable source; null selects the built-in waveform. */
	public var wavetable:DspWavetable = null;
	/** Relative tuning in cents; zero preserves the note frequency. */
	public var detuneCents:Float = 0.0;
	/** Initial and automatable normalized phase offset. */
	public var phase:Float = 0.0;

	/** A full-level sine oscillator. */
	public function new() {}

	@:allow(haxeon.audio.DspPatchBuilder)
	private function nativeValue():NativeDspOscillatorOptions {
		var result = new NativeDspOscillatorOptions();
		result.struct_size = NativeDspOscillatorOptions.byteSize();
		result.waveform = waveform;
		result.level = level;
		result.wavetable = wavetable == null ? DspWavetableHandle.invalid() : wavetable.nativeHandle();
		result.detune_cents = detuneCents;
		result.phase = phase;
		return result;
	}
}
