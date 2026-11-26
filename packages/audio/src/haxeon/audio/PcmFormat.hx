package haxeon.audio;

/** Sample encoding for interleaved PCM data passed to Clip.fromPcm. */
enum PcmFormat {
	/** 8-bit unsigned samples. */
	Unsigned8;

	/** 16-bit signed little-endian samples. */
	Signed16LE;

	/** 32-bit float little-endian samples. */
	Float32LE;
}
