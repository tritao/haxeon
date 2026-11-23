package haxeon.audio;

/** Sample encoding for interleaved PCM data passed to Clip.fromPcm. */
enum PcmFormat {
	Unsigned8;
	Signed16LE;
	Float32LE;
}
