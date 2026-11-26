package haxeon.audio;

import haxeon.platform.NativeKitError;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;

/** Provides consistent diagnostics for raw audio result calls. */
internal class AudioResult {
	public static function check(status:Result, operation:String):Void {
		if (status != Result.Ok)
			throw new NativeKitError(status, operation, NativeKit.nk_last_error());
	}
}
