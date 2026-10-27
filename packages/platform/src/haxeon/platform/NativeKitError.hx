package haxeon.platform;

import haxeon.platform.PlatformError;
import nativekit.ffi.NativeKitTypes.Result;

/** NativeKit failure with its typed platform result. */
class NativeKitError extends PlatformError {
	public final result:Result;

	public function new(result:Result, operation:String, diagnostic:Null<String>) {
		super("nativekit", result, operation, diagnostic);
		this.result = result;
	}
}
