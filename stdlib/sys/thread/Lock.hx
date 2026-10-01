package sys.thread;

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
