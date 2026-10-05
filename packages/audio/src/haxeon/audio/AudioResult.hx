package haxeon.audio;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import haxeon.platform.NativeKitError;

/** Provides consistent diagnostics for raw audio result calls. */
class AudioResult {
	public static function check(status:Result, operation:String):Void {
		if (status != Result.Ok)
			throw new NativeKitError(status, operation, NativeKit.nk_last_error());
	}
}
