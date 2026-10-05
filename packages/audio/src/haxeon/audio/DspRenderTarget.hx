package haxeon.audio;

import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;
import haxe.io.Bytes;

/** Owns one interleaved float render block returned by a DSP engine. */
class DspRenderTarget {
	public final frameCount:Int;
	public final channels:Int;
	public var samples:Bytes;

	public function new(frameCount:Int, channels:Int) {
		if (frameCount <= 0)
			throw "DSP render frame count must be positive";
		if (channels <= 0)
			throw "DSP render channel count must be positive";
		this.frameCount = frameCount;
		this.channels = channels;
		this.samples = Bytes.alloc(frameCount * channels * 4);
	}

}
