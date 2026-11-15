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
enum abstract AudioCueSelection(Int) from Int to Int {
	/** Chooses a variant using the Haxe runtime's random source. */
	var Random = 0;
	/** Visits variants in order and wraps back to the first variant. */
	var RoundRobin = 1;
}

/** Controls what an AudioCue does when its local voice pool is full. */
enum abstract AudioCueOverflow(Int) from Int to Int {
	/** Rejects the playback request and returns null. */
	var Drop = 0;
	/** Stops the oldest active cue voice and admits the new request. */
	var StealOldest = 1;
}
