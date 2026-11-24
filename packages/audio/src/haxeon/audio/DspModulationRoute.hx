package haxeon.audio;

import haxeon.platform.BindingError;

import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** One typed source-to-destination modulation route in a DSP patch. */
class DspModulationRoute {
	public final source:DspModulationSource;
	public final destination:DspModulationDestination;
	public final amount:Float;
	public final polarity:DspModulationPolarity;
	/** One-based oscillator target; zero targets all oscillator sources. */
	public final oscillatorIndex:Int;
	/** One-based oscillator source when source is Oscillator; otherwise zero. */
	public final sourceOscillatorIndex:Int;

	public function new(source:DspModulationSource, destination:DspModulationDestination,
			amount:Float, ?polarity:DspModulationPolarity, oscillatorIndex:Int = 0,
			sourceOscillatorIndex:Int = 0) {
		this.source = source;
		this.destination = destination;
		this.amount = amount;
		this.polarity = polarity == null ? DspModulationPolarity.Bipolar : polarity;
		if (oscillatorIndex < 0 || oscillatorIndex > NativeKitAudioConstants.NK_AUDIO_DSP_MAX_OSCILLATORS)
			throw BindingError.invalidArgument("DspModulationRoute.new", "DSP modulation oscillator target is invalid");
		if (oscillatorIndex != 0 && destination != DspModulationDestination.PitchSemitones && destination
			!= DspModulationDestination.OscillatorLevel && destination != DspModulationDestination.OscillatorPhase
			&& destination != DspModulationDestination.OscillatorFrequencyHz)
			throw BindingError.invalidArgument("DspModulationRoute.new",
				"DSP modulation oscillator target is only valid for oscillator destinations");
		if (source == DspModulationSource.Oscillator) {
			if (sourceOscillatorIndex <= 0
				|| sourceOscillatorIndex > NativeKitAudioConstants.NK_AUDIO_DSP_MAX_OSCILLATORS)
				throw BindingError.invalidArgument("DspModulationRoute.new",
					"DSP modulation oscillator source is invalid");
			if (oscillatorIndex == 0)
				throw BindingError.invalidArgument("DspModulationRoute.new",
					"DSP operator route requires an oscillator target");
			if (sourceOscillatorIndex == oscillatorIndex)
				throw BindingError.invalidArgument("DspModulationRoute.new",
					"DSP operator route cannot target its source oscillator");
			if (destination != DspModulationDestination.OscillatorPhase
				&& destination != DspModulationDestination.OscillatorFrequencyHz)
				throw BindingError.invalidArgument("DspModulationRoute.new",
					"DSP operator route destination is invalid");
		} else if (sourceOscillatorIndex != 0)
			throw BindingError.invalidArgument("DspModulationRoute.new",
				"DSP oscillator source index is only valid for oscillator sources");
		this.oscillatorIndex = oscillatorIndex;
		this.sourceOscillatorIndex = sourceOscillatorIndex;
	}

	@:allow(haxeon.audio.DspPatchBuilder)
	private function nativeValue():NativeDspModulationRouteOptions {
		var result = new NativeDspModulationRouteOptions();
		result.struct_size = NativeDspModulationRouteOptions.byteSize();
		result.source = source;
		result.destination = destination;
		result.polarity = polarity;
		result.amount = amount;
		result.oscillator_index = oscillatorIndex;
		result.source_oscillator_index = sourceOscillatorIndex;
		return result;
	}
}
