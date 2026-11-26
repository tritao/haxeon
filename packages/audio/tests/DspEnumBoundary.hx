import haxeon.audio.DspEnums.DspFilterType;
import haxeon.audio.DspEnums.DspLfoMode;
import haxeon.audio.DspEnums.DspModulationDestination;
import haxeon.audio.DspEnums.DspModulationPolarity;
import haxeon.audio.DspEnums.DspModulationSource;
import haxeon.audio.DspEnums.DspParameter;
import haxeon.audio.DspEnums.DspWaveform;
import haxeon.audio.DspSourceKind;
import haxeon.audio.DspSourceParameter;

/** Public DSP names expose the projected native enum types and raw values. */
class DspEnumBoundary {
	public static function run():Void {
		var parameter:DspParameter = DspParameter.FilterCutoffHz;
		var waveform:DspWaveform = DspWaveform.Saw;
		var filter:DspFilterType = DspFilterType.SvfLowPass;
		var lfo:DspLfoMode = DspLfoMode.FreeRunning;
		var source:DspModulationSource = DspModulationSource.FilterEnvelope;
		var destination:DspModulationDestination = DspModulationDestination.Pan;
		var polarity:DspModulationPolarity = DspModulationPolarity.Unipolar;
		var sourceKind:DspSourceKind = DspSourceKind.Fm2;
		var sourceParameter:DspSourceParameter = DspSourceParameter.Ratio;
		if (parameter.rawValue != 7 || waveform.rawValue != 2 || filter.rawValue != 1 || lfo.rawValue != 1
			|| source.rawValue != 3
			|| destination.rawValue != 6 || polarity.rawValue != 1 || sourceKind.rawValue != 1
			|| sourceParameter.rawValue != 0)
			throw "DSP enum raw value changed";
	}
}
