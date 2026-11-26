package haxeon.audio;

/** How a voice loads its sound, combined with `|`; the native NativeKit flags. */
typedef VoiceLoadFlags = nativekit.ffi.NativeKitAudioTypes.NativeVoiceFlags;

/**
 * How miniaudio loads file resources: Background (the default) uses resource workers; Synchronous loads on the caller,
 * without workers to join at teardown, and suits prepared, SF2 and DSP sources.
 */
typedef ResourceLoading = nativekit.ffi.NativeKitAudioTypes.NativeResourceLoading;

/** Policy used when a bus must make room for a higher-priority voice. */
typedef VoiceStealPolicy = nativekit.ffi.NativeKitAudioTypes.NativeVoiceStealPolicy;

/** Chooses which clip variant an AudioCue starts for each playback. */
enum AudioCueSelection {
	/** Chooses a variant using the Haxe runtime's random source. */
	Random;
	/** Visits variants in order and wraps back to the first variant. */
	RoundRobin;
}

/** Controls what an AudioCue does when its local voice pool is full. */
enum AudioCueOverflow {
	/** Rejects the playback request and returns null. */
	Drop;
	/** Stops the oldest active cue voice and admits the new request. */
	StealOldest;
}
