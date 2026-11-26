package haxeon.audio;

import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** Configures the ADSR amplitude or filter envelope of a DSP patch. */
class DspEnvelopeOptions {
	/** How long a note takes to reach full level. */
	public var attackSeconds:Float = 0.01;

	/** How long it then takes to fall to the sustain level. */
	public var decaySeconds:Float = 0.1;

	/** The level it holds while the note is held, from 0 to 1. */
	public var sustainLevel:Float = 0.8;

	/** How long it takes to fade after the note is released. */
	public var releaseSeconds:Float = 0.1;

	/** A quick attack and decay into a sustain at 0.8. */
	public function new() {}

	@:allow(haxeon.audio.DspPatchBuilder)
	@:allow(haxeon.audio.SampleInstrument)
	private function nativeValue():NativeDspEnvelopeOptions {
		var result = new NativeDspEnvelopeOptions();
		result.struct_size = NativeDspEnvelopeOptions.byteSize();
		result.attack_seconds = attackSeconds;
		result.decay_seconds = decaySeconds;
		result.sustain_level = sustainLevel;
		result.release_seconds = releaseSeconds;
		return result;
	}
}
