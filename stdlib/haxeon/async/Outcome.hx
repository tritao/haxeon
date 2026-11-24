package haxeon.async;

/** Terminal outcome of one asynchronous operation. */
enum Outcome<T> {
	/** The asynchronous operation completed successfully. */
	Success(value:T);
	/** The operation was cancelled. */
	Cancelled;
	/** Observation ended explicitly; work may still be running. */
	Stopped;
	/** The operation failed with an exception. */
	Failure(error:haxe.Exception);
}
