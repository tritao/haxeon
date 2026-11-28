package sys.thread;

#if wasm
/**
	A counting lock on a single-threaded target, where a thread has already run to completion by the time anything waits
	for it: each `release` lets one `wait` through. A `wait` with nothing to consume cannot be released by anyone else, so
	with a timeout it gives up at once and without one it says so instead of hanging.
**/
class Lock {
	var releases = 0;

	/** A lock with no release to consume. */
	public function new() {}

	/**
	 * Waits for a release and consumes it. With a timeout in seconds, gives up after it and returns false; without one,
	 * waits as long as it takes.
	 */
	public function wait(?timeout:Float):Bool {
		if (releases > 0) {
			releases--;
			return true;
		}
		if (timeout == null)
			throw "Lock.wait would block forever on a single-threaded target";
		return false;
	}

	/** Lets one waiter, present or future, through. */
	public function release():Void
		releases++;
}
#else
/** A counting lock, as in standard Haxe: each `release` lets one `wait` through, before or after it waits (`std.thread.Semaphore`). */
class Lock {
	final semaphore = new std.thread.Semaphore();

	/** A lock with no release to consume. */
	public function new() {}

	/**
		Waits for a release and consumes it. With a timeout in seconds, gives up
		after it and returns false; without one, waits as long as it takes.
	**/
	public function wait(?timeout:Float):Bool {
		if (timeout != null)
			return semaphore.tryAcquire(timeout);
		semaphore.acquire();
		return true;
	}

	/** Lets one waiter, present or future, through. */
	public function release():Void
		semaphore.release();
}
#end
