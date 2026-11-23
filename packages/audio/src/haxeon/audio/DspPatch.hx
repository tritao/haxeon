package haxeon.audio;

import haxeon.platform.BindingError;

import haxeon.platform.NativeKitError;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitAudio;
import nativekit.ffi.NativeKitAudioTypes;
import nativekit.ffi.NativeKitTypes;

/** Immutable reusable native DSP patch definition. */
class DspPatch implements InstrumentDefinition implements Disposable {
	final value:DspPatchHandle;
	final owned:OwnedDspPatchHandle;
	var disposed:Bool = false;

	@:allow(haxeon.audio.DspPatchBuilder)
	private function new(owned:OwnedDspPatchHandle) {
		this.owned = owned;
		this.value = owned.borrow();
	}

	/** Starts a patch builder with the native DSP defaults. */
	public static function builder():DspPatchBuilder
		return new DspPatchBuilder();

	public function nativeHandle():DspPatchHandle {
		ensureLive();
		return value;
	}

	/** Creates an engine-owned instrument that copies this patch definition. */
	public function createInstrument(engine:DspEngine):DspInstrument {
		ensureLive();
		if (engine == null)
			throw BindingError.invalidArgument("DspPatch.createInstrument", "DSP patch engine must not be null");
		return engine.createInstrument(this);
	}

	/** Releases this patch; existing instruments retain their native copy. */
	public function dispose():Void {
		if (disposed)
			return;
		var status = owned.close();
		disposed = true;
		if (status != null && status != Result.Ok)
			throw new NativeKitError(status, "audio.dsp.patch.dispose", NativeKit.nk_last_error());
	}

	public function isDisposed():Bool
		return disposed;

	function ensureLive():Void {
		if (disposed)
			throw BindingError.disposed("DspPatch.ensureLive", "DSP patch has been disposed");
	}
}
