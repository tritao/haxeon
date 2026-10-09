package haxeon.audio;

import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** Configures the ADSR amplitude envelope of a DSP patch. */
class DspEnvelopeOptions {
	public var attackSeconds:Float = 0.01;
	public var decaySeconds:Float = 0.1;
	public var sustainLevel:Float = 0.8;
	public var releaseSeconds:Float = 0.1;

	public function new() {}

	@:allow(haxeon.audio.DspPatchBuilder)
	private function nativeValue():NativeDspEnvelopeOptions {
		var result = new NativeDspEnvelopeOptions();
		result.set_struct_size(NativeDspEnvelopeOptions.size());
		result.set_attack_seconds(attackSeconds);
		result.set_decay_seconds(decaySeconds);
		result.set_sustain_level(sustainLevel);
		result.set_release_seconds(releaseSeconds);
		return result;
	}
}
