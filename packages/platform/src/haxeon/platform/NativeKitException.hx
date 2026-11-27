package haxeon.platform;

/**
 * A `NativeKitError` thrown by an API that has no `Result` for it, such as a per-frame call whose surface was lost. The
 * APIs whose failures callers handle return them instead.
 */
class NativeKitException extends PlatformError {
	/** What failed. */
	public final error:NativeKitError;

	/** `error`, raised by `operation`; `code` is NativeKit's result code, 0 where the error is not one of NativeKit's. */
	public function new(error:NativeKitError, operation:String, code:Int) {
		super("nativekit", code, operation, error.describe());
		this.error = error;
	}
}
