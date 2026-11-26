package haxeon.audio;

import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** Configures one standalone, device-independent DSP renderer. */
class DspEngineOptions {
	/** The sample rate, or zero for the backend's. */
	public var sampleRate:Int = 0;

	/** The channel count, or zero for the backend's. */
	public var channels:Int = 0;

	/** The frames per render block, or zero for the backend's. */
	public var blockSize:Int = 0;

	/** The most voices at once, or zero for the backend's limit. */
	public var maxVoices:Int = 0;

	/** Options that use the backend's defaults. */
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
