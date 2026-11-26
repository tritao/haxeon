package haxeon.audio;

import haxeon.platform.BindingError;

import nativekit.ffi.NativeKitAudioTypes;

/** Immutable PCM definition with pitch, optional loop and amplitude envelope.
 * The constructor copies normalized mono/stereo interleaved PCM and options.
 * Prepare engine-owned voices on a loading worker before publishing playback.
 */
class SampleInstrument implements InstrumentDefinition {
	final samples:Array<Float>;
	final options:NativeDspSampleOptions;

	/**
	 * An instrument playing `samples` at `rootNote`, interleaved over `channels`, looping between the loop frames when
	 * they differ.
	 */
	public function new(samples:Array<Float>, sampleRate:Int, channels:Int = 1,
			rootNote:Int = 60, gain:Float = 1, loopStartFrame:Int = 0,
			loopEndFrame:Int = 0, ?envelope:DspEnvelopeOptions) {
		if (samples == null || samples.length == 0) throw BindingError.invalidArgument("SampleInstrument.new",
			"PCM samples must not be empty");
		this.samples = samples.copy();
		var env = envelope == null ? new DspEnvelopeOptions() : envelope;
		options = new NativeDspSampleOptions();
		options.struct_size = NativeDspSampleOptions.byteSize();
		options.sample_rate = sampleRate;
		options.channels = channels;
		options.root_note = rootNote;
		options.gain = gain;
		options.loop_start_frame = loopStartFrame;
		options.loop_end_frame = loopEndFrame;
		options.set_envelope(env.nativeValue());
	}

	/** Creates the instrument on `engine`. */
	public function createInstrument(engine:DspEngine):DspInstrument {
		if (engine == null) throw BindingError.invalidArgument("SampleInstrument.createInstrument",
			"Sample instrument engine must not be null");
		return engine.createSampleInstrument(options, samples);
	}
}
