package haxeon.audio;

import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** Configures the optional LFO component of a DSP patch. */
class DspLfoOptions {
	/** Its wave shape. */
	public var waveform:DspWaveform = DspWaveform.Sine;

	/** Whether it restarts with each note or runs freely. */
	public var mode:DspLfoMode = DspLfoMode.Retrigger;

	/** Its frequency. */
	public var rateHz:Float = 0.0;

	/** Where in its cycle it starts, from 0 to 1. */
	public var phase:Float = 0.0;

	/** A stopped sine LFO. */
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
