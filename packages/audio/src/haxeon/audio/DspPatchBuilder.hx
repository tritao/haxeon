package haxeon.audio;

import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** Mutable Haxe-side builder for an immutable native DSP patch. */
class DspPatchBuilder {
	/** Pitched sources are mixed additively in source order. */
	public final oscillators:Array<DspOscillatorOptions> = [new DspOscillatorOptions()];
	public var noise:DspNoiseOptions = new DspNoiseOptions();
	public var envelope:DspEnvelopeOptions = new DspEnvelopeOptions();
	/** Independent brightness envelope; amplitude envelope controls voice lifetime. */
	public var filterEnvelope:DspEnvelopeOptions = new DspEnvelopeOptions();
	public var filterEnvelopeAmountSemitones:Float = 0;
	public var unison:DspUnisonOptions = new DspUnisonOptions();
	public var filter:DspFilterOptions = new DspFilterOptions();
	public var lfo:DspLfoOptions = new DspLfoOptions();
	public var gain:Float = 1.0;
	/** Optional specialized generator, sharing this patch envelope and filter. */
	public var source:Null<DspSourceOptions>;
	public final routes:Array<DspModulationRoute> = [];

	public function new() {}

	/** Appends a pitched source and returns this builder for fluent construction. */
	public function addOscillator(?oscillator:DspOscillatorOptions):DspPatchBuilder {
		if (oscillators.length >= NativeKitAudioConstants.NK_AUDIO_DSP_MAX_OSCILLATORS)
			throw "DSP patch oscillator limit exceeded";
		oscillators.push(oscillator == null ? new DspOscillatorOptions() : oscillator);
		return this;
	}

	/** Appends a route and returns this builder for fluent patch construction. */
	public function addRoute(route:DspModulationRoute):DspPatchBuilder {
		if (route == null)
			throw "DSP modulation route must not be null";
		if (routes.length >= NativeKitAudioConstants.NK_AUDIO_DSP_MAX_MODULATION_ROUTES)
			throw "DSP patch modulation route limit exceeded";
		routes.push(route);
		return this;
	}

	/** Convenience form of addRoute(). */
	public function modulate(source:DspModulationSource,
		destination:DspModulationDestination, amount:Float,
		?polarity:DspModulationPolarity, oscillatorIndex:Int = 0,
		sourceOscillatorIndex:Int = 0):DspPatchBuilder {
		return addRoute(new DspModulationRoute(source, destination, amount, polarity, oscillatorIndex,
			sourceOscillatorIndex));
	}

	/** Convenience form for one oscillator operator routing into another. */
	public function operatorModulate(sourceOscillatorIndex:Int,
		destination:DspModulationDestination, targetOscillatorIndex:Int,
		amount:Float, ?polarity:DspModulationPolarity):DspPatchBuilder {
		return modulate(DspModulationSource.Oscillator, destination, amount, polarity,
			targetOscillatorIndex, sourceOscillatorIndex);
	}

	/** Materializes the current builder state into an immutable native patch. */
	public function build():DspPatch {
		if (oscillators == null || noise == null || envelope == null || filter == null || lfo == null || filterEnvelope == null || unison == null)
			throw "DSP patch components must not be null";
		if (oscillators.length > NativeKitAudioConstants.NK_AUDIO_DSP_MAX_OSCILLATORS)
			throw "DSP patch oscillator limit exceeded";
		var options = new NativeDspPatchOptions();
		options.set_struct_size(NativeDspPatchOptions.size());
		options.set_oscillator_count(oscillators.length);
		for (index in 0...oscillators.length) {
			if (oscillators[index] == null)
				throw "DSP patch oscillators must not be null";
			options.set_oscillators(index, oscillators[index].nativeValue());
		}
		options.set_noise(noise.nativeValue());
		options.set_envelope(envelope.nativeValue());
		options.set_filter(filter.nativeValue());
		options.set_gain(gain);
		options.set_lfo(lfo.nativeValue());
		for (index in 0...routes.length)
			options.set_routes(index, routes[index].nativeValue());
		options.set_route_count(routes.length);
		var voice = new NativeDspVoiceOptions();
		voice.set_struct_size(NativeDspVoiceOptions.size());
		voice.set_unison_count(unison.count);
		voice.set_unison_detune_cents(unison.detuneCents);
		voice.set_unison_stereo_spread(unison.stereoSpread);
		voice.set_filter_envelope(filterEnvelope.nativeValue());
		voice.set_filter_envelope_amount_semitones(filterEnvelopeAmountSemitones);
		if (source != null) {
			var made = NativeKitAudio.nk_audio_dsp_patch_create_source_extended(options,voice,source.nativeValue(),source.samples);
			AudioResult.check(made.status, "audio.dsp.patch.buildSource");
			return new DspPatch(made.out_patch);
		}
		var made = NativeKitAudio.nk_audio_dsp_patch_create_extended(options,voice);
		AudioResult.check(made.status, "audio.dsp.patch.build");
		return new DspPatch(made.out_patch);
	}
}
