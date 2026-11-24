package haxeon.audio;

import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** Configures the ADSR amplitude or filter envelope of a DSP patch. */
class DspEnvelopeOptions {
	public var attackSeconds:Float = 0.01;
	public var decaySeconds:Float = 0.1;
	public var sustainLevel:Float = 0.8;
	public var releaseSeconds:Float = 0.1;

	public function new() {}

	@:allow(haxeon.audio.DspPatchBuilder)
	@:allow(haxeon.audio.SampleInstrument)
	private function nativeValue():NativeDspEnvelopeOptions {
		var result = new NativeDspEnvelopeOptions();
		result.struct_size = NativeDspEnvelopeOptions.byteSize();
		result.attack_seconds = attackSeconds;
		result.decay_seconds = decaySeconds;
		result.sustain_level = sustainLevel;
		result.release_seconds = releaseSeconds;
		return result;
	}
}
