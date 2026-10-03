package sys.thread;

#if wasm
/**
	A counting lock on a single-threaded target, where a thread has already run to completion by the time anything waits
	for it: each `release` lets one `wait` through. A `wait` with nothing to consume cannot be released by anyone else, so
	with a timeout it gives up at once and without one it says so instead of hanging.
**/
class Lock {
	var releases = 0;

	public function new() {}

	public function wait(?timeout:Float):Bool {
		if (releases > 0) {
			releases--;
			return true;
		}
		if (timeout == null)
			throw "Lock.wait would block forever on a single-threaded target";
		return false;
	}

	public function release():Void
		releases++;
}
#else
/**
	A counting lock, as in standard Haxe: each `release` lets one `wait` through,
	whether the release comes before or after the wait starts.
**/
class Lock {
	final condition = new Condition();
	var releases = 0;

	public function new() {}

	/**
		Waits for a release and consumes it. With a timeout in seconds, gives up
		after it and returns false; without one, waits as long as it takes.
	**/
	public function wait(?timeout:Float):Bool {
		condition.acquire();
		if (timeout == null) {
			while (releases == 0)
				condition.wait();
		} else {
			var deadline = Sys.time() + timeout;
			while (releases == 0) {
				var remaining = deadline - Sys.time();
				if (remaining <= 0.0)
					break;
				condition.timedWait(remaining);
			}
		}
		var acquired = releases > 0;
		if (acquired)
			releases--;
		condition.release();
		return acquired;
	}

	/** Lets one waiter, present or future, through. */
	public function release():Void {
		condition.acquire();
		releases++;
		condition.signal();
		condition.release();
	}
}
#end
