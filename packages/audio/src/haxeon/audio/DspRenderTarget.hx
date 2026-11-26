package haxeon.audio;

import haxeon.platform.BindingError;

import haxe.io.Bytes;
import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** Owns one interleaved float render block returned by a DSP engine. */
class DspRenderTarget {
	/** How many frames it holds. */
	public final frameCount:Int;

	/** How many channels each frame has. */
	public final channels:Int;

	/** The interleaved 32-bit float samples. */
	public var samples:Bytes;

	/** A silent block of `frameCount` frames of `channels` channels. */
	public function new(frameCount:Int, channels:Int) {
		if (frameCount <= 0)
			throw BindingError.invalidArgument("DspRenderTarget.new", "DSP render frame count must be positive");
		if (channels <= 0)
			throw BindingError.invalidArgument("DspRenderTarget.new", "DSP render channel count must be positive");
		this.frameCount = frameCount;
		this.channels = channels;
		this.samples = Bytes.alloc(frameCount * channels * 4);
	}

}
