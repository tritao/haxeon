package haxeon.audio;

import haxeon.platform.BindingError;

import haxeon.audio.Enums.VoiceStealPolicy;
import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;

/** Configures voice admission for a bus and all of its child buses. */
class BusConcurrencyOptions {
	/** Maximum number of audible voices in the bus subtree; zero means unlimited. */
	public var maxVoices:Int = 0;
	/** Policy used to make room when maxVoices is reached. */
	public var stealPolicy:VoiceStealPolicy = VoiceStealPolicy.None;
	/** Keeps admitted voices advancing silently until capacity becomes available. */
	public var virtualize:Bool = false;

	/** Options with no voice limit. */
	public function new() {}

	@:allow(haxeon.audio.Bus)
	private function nativeValue():NativeBusConcurrencyOptions {
		if (maxVoices < 0)
			throw BindingError.invalidArgument("BusConcurrencyOptions.nativeValue",
				"Audio bus maxVoices must be non-negative");
		var result = new NativeBusConcurrencyOptions();
		result.struct_size = NativeBusConcurrencyOptions.byteSize();
		result.max_voices = maxVoices;
		result.steal_policy = stealPolicy;
		result.virtualize = virtualize;
		return result;
	}

	@:allow(haxeon.audio.Bus)
	private static function fromNative(value:NativeBusConcurrencyOptions):BusConcurrencyOptions {
		var result = new BusConcurrencyOptions();
		result.maxVoices = value.max_voices;
		result.stealPolicy = value.steal_policy;
		result.virtualize = value.virtualize;
		return result;
	}
}
