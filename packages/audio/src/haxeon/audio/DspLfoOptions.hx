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
		result.struct_size = NativeDspLfoOptions.byteSize();
		result.waveform = waveform;
		result.mode = mode;
		result.rate_hz = rateHz;
		result.phase = phase;
		return result;
	}
}
