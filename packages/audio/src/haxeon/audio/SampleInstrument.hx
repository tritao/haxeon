package haxeon.audio;

import nativekit.ffi.NativeKitAudioTypes;

/** Immutable PCM definition with pitch, optional loop and amplitude envelope.
 * The constructor copies normalized mono/stereo interleaved PCM and options.
 * Prepare engine-owned voices on a loading worker before publishing playback.
 */
class SampleInstrument implements InstrumentDefinition {
    final samples:Array<Float>;
    final options:NativeDspSampleOptions;
    public function new(samples:Array<Float>, sampleRate:Int, channels:Int = 1,
        rootNote:Int = 60, gain:Float = 1, loopStartFrame:Int = 0,
        loopEndFrame:Int = 0, ?envelope:DspEnvelopeOptions) {
        if (samples == null || samples.length == 0) throw "PCM samples must not be empty";
        this.samples = samples.copy();
        var env = envelope == null ? new DspEnvelopeOptions() : envelope;
        options = new NativeDspSampleOptions();
        options.set_struct_size(NativeDspSampleOptions.size());
        options.set_sample_rate(sampleRate); options.set_channels(channels);
        options.set_root_note(rootNote); options.set_gain(gain);
        options.set_loop_start_frame(loopStartFrame); options.set_loop_end_frame(loopEndFrame);
        options.set_envelope(env.nativeValue());
    }
    public function createInstrument(engine:DspEngine):DspInstrument {
        if (engine == null) throw "Sample instrument engine must not be null";
        return engine.createSampleInstrument(options, samples);
    }
}
