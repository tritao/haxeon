package audiolab;

import haxeon.audio.DspEnvelopeOptions;
import haxeon.audio.DspEnums.DspFilterType;
import haxeon.audio.DspEnums.DspLfoMode;
import haxeon.audio.DspEnums.DspModulationDestination;
import haxeon.audio.DspEnums.DspModulationPolarity;
import haxeon.audio.DspEnums.DspModulationSource;
import haxeon.audio.DspNoiseOptions;
import haxeon.audio.DspOscillatorOptions;
import haxeon.audio.DspPatchBuilder;
import haxeon.audio.DspEnums.DspWaveform;

/** Presets used by Audio Lab. Each preset is materialized as a NativeKit DSP patch. */
typedef AudioLabPresetId = String;

class AudioLabPreset {
	public static inline var Subtractive:AudioLabPresetId = "subtractive";
	public static inline var FmBell:AudioLabPresetId = "fm-bell";
	public static inline var DrumKit:AudioLabPresetId = "drum-kit";
	public static inline var Bass:AudioLabPresetId = "bass";
	public static inline var Pad:AudioLabPresetId = "pad";
	public static inline var NoiseTexture:AudioLabPresetId = "noise";
	public static inline var Layered:AudioLabPresetId = "layered";

	public static function label(id:AudioLabPresetId):String {
		return switch (id) {
			case "subtractive": "Subtractive";
			case "fm-bell": "FM Bell";
			case "drum-kit": "Procedural Drums";
			case "bass": "Bass";
			case "pad": "Pad";
			case "noise": "Noise Texture";
			case "layered": "Layered";
			case _: "Unknown";
		}
	}

	public static function ids():Array<AudioLabPresetId>
		return [Subtractive, FmBell, DrumKit, Bass, Pad, NoiseTexture, Layered];

	public static function routeSummary(id:AudioLabPresetId):Array<String> {
		return switch (id) {
			case "subtractive": ["Envelope 1  ->  Filter Cutoff       +0.75", "Velocity   ->  Amp Level            +1.00"];
			case "fm-bell": ["Oscillator 1  ->  Oscillator 2 Freq  +220 Hz", "Envelope 1   ->  Amp Level            +1.00"];
			case "drum-kit": ["Envelope 1  ->  Filter Cutoff       +2400 Hz", "Velocity     ->  Amp Level            +1.00"];
			case "bass": ["Envelope 1  ->  Filter Cutoff       +900 Hz", "LFO 1        ->  Oscillator 1 Pitch   +0.15 st"];
			case "pad": ["LFO 1        ->  Filter Cutoff       +900 Hz", "LFO 1        ->  Amp Level            +0.20"];
			case "noise": ["Envelope 1  ->  Filter Cutoff       +1800 Hz", "LFO 1        ->  Amp Level            +0.35"];
			case "layered": ["LFO 1        ->  Oscillator 1 Pitch   +0.35 st", "Envelope 1  ->  Filter Cutoff       +1200 Hz"];
			case _: [];
		};
	}

	/** Creates the immutable patch used by a selected preset. */
	public static function build(id:AudioLabPresetId):DspPatchBuilder {
		var builder = new DspPatchBuilder();
		builder.oscillators.resize(0);
		builder.noise = new DspNoiseOptions();
		builder.envelope = new DspEnvelopeOptions();
		builder.filter.type = DspFilterType.SvfLowPass;
		builder.lfo.mode = DspLfoMode.Retrigger;
		builder.gain = 0.55;

		switch (id) {
			case "subtractive":
				add(builder, DspWaveform.Saw, 0.72, 0.0);
				add(builder, DspWaveform.Square, 0.22, 7.0);
				builder.filter.cutoffHz = 1450.0;
				builder.filter.resonance = 0.24;
				builder.envelope.attackSeconds = 0.012;
				builder.envelope.decaySeconds = 0.18;
				builder.envelope.sustainLevel = 0.68;
				builder.envelope.releaseSeconds = 0.22;

			case "fm-bell":
				add(builder, DspWaveform.Sine, 0.8, 0.0);
				add(builder, DspWaveform.Sine, 0.55, 0.0);
				builder.operatorModulate(1, DspModulationDestination.OscillatorFrequencyHz,
					2, 220.0);
				builder.filter.type = DspFilterType.None;
				builder.filter.cutoffHz = 0.0;
				builder.envelope.attackSeconds = 0.002;
				builder.envelope.decaySeconds = 1.1;
				builder.envelope.sustainLevel = 0.08;
				builder.envelope.releaseSeconds = 1.4;
				builder.gain = 0.42;

			case "drum-kit":
				add(builder, DspWaveform.Sine, 0.2, 0.0);
				builder.noise.level = 0.86;
				builder.filter.cutoffHz = 3200.0;
				builder.filter.resonance = 0.18;
				builder.envelope.attackSeconds = 0.001;
				builder.envelope.decaySeconds = 0.12;
				builder.envelope.sustainLevel = 0.04;
				builder.envelope.releaseSeconds = 0.05;
				builder.gain = 0.34;

			case "bass":
				add(builder, DspWaveform.Saw, 0.9, -8.0);
				add(builder, DspWaveform.Square, 0.18, 0.0);
				builder.filter.cutoffHz = 520.0;
				builder.filter.resonance = 0.34;
				builder.envelope.attackSeconds = 0.008;
				builder.envelope.decaySeconds = 0.15;
				builder.envelope.sustainLevel = 0.82;
				builder.envelope.releaseSeconds = 0.16;
				builder.lfo.rateHz = 0.35;
				builder.modulate(DspModulationSource.Lfo, DspModulationDestination.PitchSemitones,
					0.15, DspModulationPolarity.Bipolar);

			case "pad":
				add(builder, DspWaveform.Sine, 0.62, 0.0);
				add(builder, DspWaveform.Triangle, 0.38, 9.0);
				add(builder, DspWaveform.Saw, 0.14, -9.0);
				builder.filter.cutoffHz = 2200.0;
				builder.filter.resonance = 0.12;
				builder.envelope.attackSeconds = 0.48;
				builder.envelope.decaySeconds = 0.75;
				builder.envelope.sustainLevel = 0.72;
				builder.envelope.releaseSeconds = 1.2;
				builder.lfo.rateHz = 0.18;
				builder.modulate(DspModulationSource.Lfo, DspModulationDestination.FilterCutoffHz,
					900.0, DspModulationPolarity.Bipolar);
				builder.modulate(DspModulationSource.Lfo, DspModulationDestination.Amplitude,
					0.20, DspModulationPolarity.Unipolar);

			case "noise":
				builder.noise.level = 0.92;
				builder.filter.cutoffHz = 2800.0;
				builder.filter.resonance = 0.3;
				builder.envelope.attackSeconds = 0.08;
				builder.envelope.decaySeconds = 0.35;
				builder.envelope.sustainLevel = 0.58;
				builder.envelope.releaseSeconds = 0.65;
				builder.lfo.rateHz = 0.26;
				builder.modulate(DspModulationSource.Lfo, DspModulationDestination.Amplitude,
					0.35, DspModulationPolarity.Unipolar);
				builder.gain = 0.3;

			case "layered":
				add(builder, DspWaveform.Saw, 0.46, -12.0);
				add(builder, DspWaveform.Sine, 0.4, 0.0);
				add(builder, DspWaveform.Square, 0.16, 12.0);
				builder.filter.cutoffHz = 1850.0;
				builder.filter.resonance = 0.2;
				builder.envelope.attackSeconds = 0.07;
				builder.envelope.decaySeconds = 0.28;
				builder.envelope.sustainLevel = 0.62;
				builder.envelope.releaseSeconds = 0.5;
				builder.lfo.rateHz = 0.22;
				builder.modulate(DspModulationSource.Lfo, DspModulationDestination.PitchSemitones,
					0.35, DspModulationPolarity.Bipolar, 1);
		};
		return builder;
	}

	static function add(builder:DspPatchBuilder, waveform:DspWaveform, level:Float,
		detune:Float):Void {
		var oscillator = new DspOscillatorOptions();
		oscillator.waveform = waveform;
		oscillator.level = level;
		oscillator.detuneCents = detune;
		builder.addOscillator(oscillator);
	}
}
