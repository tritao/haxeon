package haxeon.audio;

import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** Configures the optional LFO component of a DSP patch. */
class DspLfoOptions {
	public var waveform:DspWaveform = DspWaveform.Sine;
	public var mode:DspLfoMode = DspLfoMode.Retrigger;
	public var rateHz:Float = 0.0;
	public var phase:Float = 0.0;

	public function new() {}

	@:allow(haxeon.audio.DspPatchBuilder)
	private function nativeValue():NativeDspLfoOptions {
		var result = new NativeDspLfoOptions();
		result.set_struct_size(NativeDspLfoOptions.size());
		result.set_waveform(waveform);
		result.set_mode(mode);
		result.set_rate_hz(rateHz);
		result.set_phase(phase);
		return result;
	}
}
