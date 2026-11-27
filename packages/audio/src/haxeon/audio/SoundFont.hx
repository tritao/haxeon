package haxeon.audio;

import haxeon.platform.BindingError;

import haxe.io.Bytes;
import haxeon.platform.NativeKitError;
import haxeon.platform.NativeKitStatus;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;
import nativekit.ffi.NativeKitTypes.Result as NativeResult;

/** One preset of a bank: its index, bank and program numbers, and name. */
typedef SoundFontPresetInfo = {
	var index:Int;
	var bank:Int;
	var program:Int;
	var name:String;
}

/** Immutable decoded uncompressed SF2 bank. Load on a preparation worker.
 * SF2 modulators and region chorus/reverb sends are currently unsupported.
 * Instruments retain sample data after the bank handle is disposed.
 */
class SoundFont implements Disposable {
	final owned:OwnedSoundFontHandle;
	final value:SoundFontHandle;
	var disposed:Bool = false;
	private function new(owned:OwnedSoundFontHandle) {
		this.owned = owned;
		value = owned.borrow();
	}

	/** Decodes an SF2 bank from `bytes`, or answers why it cannot (`InvalidData` for what is not one). */
	public static function fromMemory(bytes:Bytes):Result<SoundFont, NativeKitError> {
		if (bytes == null || bytes.length == 0) throw BindingError.invalidArgument("SoundFont.fromMemory",
			"SoundFont data must not be empty");
		var result = NativeKitAudio.nk_audio_soundfont_load_memory(bytes);
		return NativeKitStatus.made(result.status, "audio.soundfont.load", NativeKit.nk_last_error(),
			() -> new SoundFont(result.out_soundfont));
	}

	internal function nativeHandle():SoundFontHandle {
		if (disposed) throw BindingError.disposed("SoundFont.nativeHandle", "SoundFont has been disposed");
		return value;
	}

	/** The bank's presets. */
	public function presets():Array<SoundFontPresetInfo> {
		nativeHandle();
		var result = NativeKitAudio.nk_audio_soundfont_get_preset_count(value);
		AudioResult.check(result.status, "audio.soundfont.presets");
		var output:Array<SoundFontPresetInfo> = [];
		for (i in 0...result.out_count) {
			var info = new NativeSoundFontPresetInfo();
			info.struct_size = NativeSoundFontPresetInfo.byteSize();
			var details = NativeKitAudio.nk_audio_soundfont_get_preset_info(value, i, info);
			AudioResult.check(details.status, "audio.soundfont.presetInfo");
			info = details.out_info;
			output.push({index: i, bank: info.bank, program: info.program, name: info.name});
		}
		return output;
	}

	/** Preset `index`, played at `gain`. */
	public function preset(index:Int, gain:Float = 1.0):SoundFontPreset {
		nativeHandle();
		return new SoundFontPreset(this, index, gain);
	}
	public function dispose():Void {
		if (disposed) return;
		var status = owned.close();
		disposed = true;
		if (status != null && status != NativeResult.Ok)
			throw NativeKitStatus.failure(status, "audio.soundfont.dispose", NativeKit.nk_last_error());
	}
}

/** One preset of a SoundFont, ready to create instruments from. */
class SoundFontPreset implements InstrumentDefinition {
	final font:SoundFont;
	final index:Int;
	final gain:Float;
	internal function new(font:SoundFont, index:Int, gain:Float) {
		if (font == null || index < 0 || !Math.isFinite(gain) || gain < 0 || gain > 4)
			throw BindingError.invalidArgument("SoundFontPreset.new", "Invalid SoundFont preset");
		this.font = font;
		this.index = index;
		this.gain = gain;
	}

	/** Creates the instrument on `engine`. */
	public function createInstrument(engine:DspEngine):DspInstrument
		return engine.createSoundFontInstrument(font, index, gain);
}
