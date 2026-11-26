package haxeon.audio;

import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** Configures the process-wide playback device before the first audio use. */
class DeviceOptions {
	/** Selects the backend default playback device. */
	public static inline var DEFAULT_DEVICE:Int = -1;

	/** Playback device index returned by Mixer.deviceCount/deviceName. */
	public var playbackDeviceIndex:Int = DEFAULT_DEVICE;
	/** Requested output sample rate, or zero for the backend default. */
	public var sampleRate:Int = 0;
	/** Requested output channel count, or zero for the backend default. */
	public var channels:Int = 0;
	/** Requested device period in PCM frames, or zero for the backend default. */
	public var periodSizeInFrames:Int = 0;
	/** Requested device period in milliseconds, or zero for the backend default. */
	public var periodSizeInMilliseconds:Int = 0;
	/** Prevents the device from starting until Mixer.startDevice is called. */
	public var noAutoStart:Bool = false;
	/** Miniaudio file loading policy. Synchronous mode may block during file loading
	 * and is unsuitable for background file decoding or streamed miniaudio voices.
	 * NativeKit DSP, SF2 and stream-worker behavior is independent. */
	public var resourceLoading:ResourceLoading = ResourceLoading.Background;

	/** Options for the default playback device. */
	public function new() {}

	@:allow(haxeon.audio.Mixer)
	private function nativeValue():NativeDeviceOptions {
		var result = new NativeDeviceOptions();
		result.struct_size = NativeDeviceOptions.byteSize();
		result.playback_device_index = playbackDeviceIndex;
		result.sample_rate = sampleRate;
		result.channels = channels;
		result.period_size_in_frames = periodSizeInFrames;
		result.period_size_in_milliseconds = periodSizeInMilliseconds;
		result.no_auto_start = noAutoStart;
		result.resource_loading = resourceLoading;
		return result;
	}
}
