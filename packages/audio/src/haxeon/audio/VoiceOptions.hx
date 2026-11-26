package haxeon.audio;

import haxeon.audio.Enums.VoiceLoadFlags;
import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** Configures a voice's primitive playback behavior. */
class VoiceOptions {
	/** Whether the voice loops. */
	public var looping:Bool = false;

	/** Whether it decodes while it plays instead of all up front. */
	public var streaming:Bool = false;

	/** Whether it loads in the background, when the backend can. */
	public var asynchronous:Bool = false;

	/** Options for a plain, decoded, one-shot voice. */
	public function new() {}

	@:allow(haxeon.audio.Voice)
	private function nativeValue():NativeVoiceOptions {
		var result = new NativeVoiceOptions();
		result.struct_size = NativeVoiceOptions.byteSize();
		var flags = VoiceLoadFlags.empty();
		if (looping)
			flags = flags | VoiceLoadFlags.Looping;
		if (streaming)
			flags = flags | VoiceLoadFlags.Streaming;
		if (asynchronous)
			flags = flags | VoiceLoadFlags.Asynchronous;
		result.flags = flags;
		return result;
	}
}
