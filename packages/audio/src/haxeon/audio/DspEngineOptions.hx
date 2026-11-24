package haxeon.audio;

import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** Configures one standalone, device-independent DSP renderer. */
class DspEngineOptions {
	public var sampleRate:Int = 0;
	public var channels:Int = 0;
	public var blockSize:Int = 0;
	public var maxVoices:Int = 0;

	public function new() {}

	@:allow(haxeon.audio.DspEngine)
	private function nativeValue():NativeDspEngineOptions {
		var result = new NativeDspEngineOptions();
		result.struct_size = NativeDspEngineOptions.byteSize();
		result.sample_rate = sampleRate;
		result.channels = channels;
		result.block_size = blockSize;
		result.max_voices = maxVoices;
		return result;
	}
}
