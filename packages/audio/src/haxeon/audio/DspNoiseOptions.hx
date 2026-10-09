package haxeon.audio;

import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** Configures the additive white-noise component of a DSP patch. */
class DspNoiseOptions {
	public var level:Float = 0.0;

	public function new() {}

	@:allow(haxeon.audio.DspPatchBuilder)
	private function nativeValue():NativeDspNoiseOptions {
		var result = new NativeDspNoiseOptions();
		result.set_struct_size(NativeDspNoiseOptions.size());
		result.set_level(level);
		return result;
	}
}
