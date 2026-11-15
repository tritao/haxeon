package haxeon.audio;

import haxeon.audio.Enums.VoiceLoadFlags;
import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** Configures a voice's primitive playback behavior. */
class VoiceOptions {
	public var looping:Bool = false;
	public var streaming:Bool = false;
	public var asynchronous:Bool = false;

	public function new() {}

	@:allow(haxeon.audio.Voice)
	private function nativeValue():NativeVoiceOptions {
		var result = new NativeVoiceOptions();
		result.set_struct_size(NativeVoiceOptions.size());
		var flags = VoiceLoadFlags.empty();
		if (looping)
			flags = flags | VoiceLoadFlags.Looping;
		if (streaming)
			flags = flags | VoiceLoadFlags.Streaming;
		if (asynchronous)
			flags = flags | VoiceLoadFlags.Asynchronous;
		result.set_flags(flags);
		return result;
	}
}
