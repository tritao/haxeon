package haxeon.platform;

import haxeon.platform.PlatformError;
import nativekit.ffi.NativeKitTypes.Result;

/** NativeKit failure with its typed platform result. */
class NativeKitError extends PlatformError {
	/** The NativeKit result code. */
	public final result:Result;

	/** An error for `result` in `operation`. */
	public function new(result:Result, operation:String, diagnostic:Null<String>) {
		super("nativekit", result.rawValue(), operation, diagnostic);
		this.result = result;
	}
}
