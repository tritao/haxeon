package haxeon.async;

/**
 * How one asynchronous operation ended for its observers. An operation whose failures are expected gives them in its
 * value (`Future<Result<T, E>>`); a producer's bug throws where it happens rather than settling the future.
 */
enum Outcome<T> {
	/** The operation completed with `value`. */
	Success(value:T);

	/** The operation was cancelled. */
	Cancelled;

	/** Observation ended explicitly; work may still be running. */
	Stopped;
}
