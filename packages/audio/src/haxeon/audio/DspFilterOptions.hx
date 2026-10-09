package haxeon.audio;

import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** Configures the optional filter component of a DSP patch. */
class DspFilterOptions {
	public var type:DspFilterType = DspFilterType.None;
	public var cutoffHz:Float = 0.0;
	public var resonance:Float = 0.0;

	public function new() {}

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
