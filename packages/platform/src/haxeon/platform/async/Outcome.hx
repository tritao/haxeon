package haxeon.platform.async;

import haxeon.platform.PlatformError;

/** Result of one asynchronous NativeKit request. */
enum Outcome<T> {
	/** The asynchronous operation completed successfully. */
	Success(value:T);
	/** The operation was cancelled, dismissed, or ended by runtime shutdown. */
	Cancelled;
	/** Managed observation ended explicitly; native work may still be running. */
	Stopped;
	/** The operation failed with a structured backend or managed error. */
	Failure(error:PlatformError);
}
