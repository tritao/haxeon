package haxeon.audio;

import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** Configures the optional filter component of a DSP patch. */
class DspFilterOptions {
	public var type:DspFilterType = DspFilterType.None;
	public var cutoffHz:Float = 0.0;
	public var resonance:Float = 0.0;
	/** Nonlinear saturation, [0, 1]; zero gives a linear resonance response. */
	public var drive:Float = 0.5;

	public function new() {}

	/** Nominal linear SVF Q, [0.5, 100]. Drive suppresses the measured resonance peak. */
	public function setQ(q:Float):DspFilterOptions {
		if (!Math.isFinite(q) || q<0.5 || q>100) throw "SVF Q must be 0.5..100";
		// Daisy's damping is 2*(1-resonance^(1/4)); keep its domain behind the facade.
		resonance=Math.pow(1-0.5/q,4);
		return this;
	}

	@:allow(haxeon.audio.DspPatchBuilder)
	private function nativeValue():NativeDspFilterOptions {
		var result = new NativeDspFilterOptions();
		result.set_struct_size(NativeDspFilterOptions.size());
		result.set_type(type);
		result.set_cutoff_hz(cutoffHz);
		result.set_resonance(resonance);
		return result;
	}
}
