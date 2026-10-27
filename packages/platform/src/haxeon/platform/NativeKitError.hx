package haxeon.platform;

import nativekit.ffi.NativeKitTypes;

/** NativeKit failure with its typed platform result. */
class NativeKitError extends NativeError {
	public final result:Result;

	public function new(result:Result, operation:String, diagnostic:Null<String>) {
		super("nativekit", result, operation, diagnostic);
		this.result = result;
	}
}
