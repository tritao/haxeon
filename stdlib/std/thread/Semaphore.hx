package std.thread;

#if wasm
#error "std.thread is not available on Wasm: a Wasm module runs on one thread"
#end

/**
 * Permits handed between threads: `release` adds one, and `acquire` takes one, waiting until there is one. A release
 * before the acquire counts as much as one after it.
 */
class Semaphore {
	final condition = new Condition();
	var permits:Int;

	/** A semaphore holding `permits` permits. */
	public function new(permits:Int = 0) {
		if (permits < 0)
			throw new haxe.Exception("std.thread.Semaphore: a semaphore cannot start with fewer than no permits");
		this.permits = permits;
	}

	/** Takes a permit, waiting as long as it takes for one. */
	public function acquire():Void {
		condition.acquire();
		defer condition.release();
		while (permits == 0)
			condition.wait();
		permits--;
	}

	/** Takes a permit if one comes within `timeoutSeconds` (0: only one there already): whether it took one. */
	public function tryAcquire(timeoutSeconds:Float = 0):Bool {
		condition.acquire();
		defer condition.release();
		// The clock a wait is measured on must not move with the system's time.
		var deadline = monotonicTime() + timeoutSeconds;
		while (permits == 0) {
			var remaining = deadline - monotonicTime();
			if (remaining <= 0)
				return false;
			condition.wait(remaining);
		}
		permits--;
		return true;
	}

	/** Adds a permit, letting one waiter, present or future, through. */
	public function release():Void {
		condition.acquire();
		defer condition.release();
		permits++;
		condition.signal();
	}
}

@:hlNative("haxeon_runtime", "__sys_monotonic_time")
internal extern function monotonicTime():Float;
