package haxeon.audio;

import haxeon.platform.BindingError;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;
import haxeon.platform.NativeKitError;
import haxe.io.Bytes;
import sys.io.File;

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
class SoundFont {
    final owned:OwnedSoundFontHandle;
    final value:SoundFontHandle;
    var disposed:Bool = false;
    private function new(owned:OwnedSoundFontHandle) {
        this.owned = owned;
        value = owned.borrow();
    }
    public static function fromMemory(bytes:Bytes):SoundFont {
        if (bytes == null || bytes.length == 0) throw BindingError.invalidArgument("SoundFont.fromMemory", "SoundFont data must not be empty");
        var result = NativeKitAudio.nk_audio_soundfont_load_memory(bytes);
        AudioResult.check(result.status, "audio.soundfont.load");
        return new SoundFont(result.out_soundfont);
    }
    public static function fromFile(path:String):SoundFont {
        if (path == null || path.length == 0) throw BindingError.invalidArgument("SoundFont.fromFile", "SoundFont path must not be empty");
        return fromMemory(File.getBytes(path));
    }
    public function nativeHandle():SoundFontHandle {
        if (disposed) throw BindingError.disposed("SoundFont.nativeHandle", "SoundFont has been disposed");
        return value;
    }
    public function presets():Array<SoundFontPresetInfo> {
        nativeHandle();
        var result = NativeKitAudio.nk_audio_soundfont_get_preset_count(value);
        AudioResult.check(result.status, "audio.soundfont.presets");
        var output:Array<SoundFontPresetInfo> = [];
        for (i in 0...result.out_count) {
            var info = new NativeSoundFontPresetInfo();
            info.set_struct_size(NativeSoundFontPresetInfo.size());
            var details = NativeKitAudio.nk_audio_soundfont_get_preset_info(value, i, info);
            AudioResult.check(details.status, "audio.soundfont.presetInfo");
            info = details.out_info;
            output.push({index:i, bank:info.get_bank(), program:info.get_program(), name:info.get_name()});
        }
        return output;
    }
    public function preset(index:Int, gain:Float = 1.0):SoundFontPreset {
        nativeHandle();
        return new SoundFontPreset(this, index, gain);
    }
    public function dispose():Void {
        if (disposed) return;
        var status = owned.close();
        disposed = true;
        if (status != null && status != Result.Ok)
            throw new NativeKitError(status, "audio.soundfont.dispose", NativeKit.nk_last_error());
    }
}

class SoundFontPreset implements InstrumentDefinition {
    final font:SoundFont;
    final index:Int;
    final gain:Float;
    public function new(font:SoundFont, index:Int, gain:Float) {
        if (font == null || index < 0 || !Math.isFinite(gain) || gain < 0 || gain > 4)
            throw BindingError.invalidArgument("SoundFontPreset.new", "Invalid SoundFont preset");
        this.font = font; this.index = index; this.gain = gain;
    }
    public function createInstrument(engine:DspEngine):DspInstrument
        return engine.createSoundFontInstrument(font, index, gain);
}
