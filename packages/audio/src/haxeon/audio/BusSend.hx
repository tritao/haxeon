package haxeon.audio;

import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;
import nativekit.ffi.NativeKitTypes;

/** Independent post-fader route. Destroying either endpoint invalidates it. */
class BusSend {
	final value:BusSendHandle;
	final owned:OwnedBusSendHandle;
	var disposed:Bool = false;

	@:allow(haxeon.audio.Bus)
	private function new(owned:OwnedBusSendHandle) {
		this.owned = owned;
		value = owned.borrow();
	}
	public function setVolume(volume:Float):Void {
		ensureLive();
		AudioResult.check(NativeKitAudio.nk_audio_bus_send_set_volume(value, volume), "audio.send.setVolume");
	}
	public function volume():Float {
		ensureLive();
		var result = NativeKitAudio.nk_audio_bus_send_get_volume(value);
		AudioResult.check(result.status, "audio.send.volume");
		return result.out_volume;
	}
	public function dispose():Void {
		if (disposed) return;
		var status = owned.close();
		disposed = true;
		if (status != null && status != Result.ErrorInvalidHandle)
			AudioResult.check(status, "audio.send.dispose");
	}
	public function isDisposed():Bool return disposed;
	function ensureLive():Void {
		if (disposed) throw "Audio send has been disposed";
	}
}
