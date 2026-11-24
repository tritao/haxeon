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
		result.struct_size = NativeDspNoiseOptions.byteSize();
		result.level = level;
		return result;
	}
}
