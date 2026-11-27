package haxeon.audio;

import haxeon.platform.NativeKitStatus;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;

/** Provides consistent diagnostics for raw audio result calls. */
internal class AudioResult {
	public static function check(status:Result, operation:String):Void {
		if (status != Result.Ok)
			throw NativeKitStatus.failure(status, operation, NativeKit.nk_last_error());
	}
}
