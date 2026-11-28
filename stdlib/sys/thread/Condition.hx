package sys.thread;

#if wasm
/**
 * Condition variable on a single-threaded target: no other thread can signal, so a wait that has to wait never ends.
 * `wait` says so instead of hanging; `timedWait` times out at once.
 */
class Condition {
	/** A condition with its own lock, not held. */
	public function new() {}

	/**
	 * Takes the lock, waiting while another thread holds it. A thread may take it again; each take needs its `release`.
	 */
	public function acquire():Void {}

	/** Gives back the lock once. */
	public function release():Void {}

	/** Wakes one thread waiting in `wait` or `timedWait`, if any. */
	public function signal():Void {}

	/** Wakes every thread waiting in `wait` or `timedWait`. */
	public function broadcast():Void {}

	/**
	 * With the lock held, releases it, waits for a `signal` or `broadcast`, and takes it again before returning. A wait
	 * can also end spuriously: check the state it waits for in a loop.
	 */
	public function wait():Void throw "Condition.wait would block forever on a single-threaded target";

	/** As `wait`, giving up after `timeout` seconds: whether it was woken before then. */
	public function timedWait(timeout:Float):Bool return false;
}
#else
/** A condition variable with its own recursive lock (`std.thread.Condition`). */
class Condition {
	final condition = new std.thread.Condition();

	/** A condition with its own lock, not held. */
	public function new() {}

	/**
	 * Takes the lock, waiting while another thread holds it. A thread may take it again; each take needs its `release`.
	 */
	public function acquire():Void
		condition.acquire();

	/** Gives back the lock once. */
	public function release():Void
		condition.release();

	/** Wakes one thread waiting in `wait` or `timedWait`, if any. */
	public function signal():Void
		condition.signal();

	/** Wakes every thread waiting in `wait` or `timedWait`. */
	public function broadcast():Void
		condition.broadcast();

	/**
	 * With the lock held, releases it, waits for a `signal` or `broadcast`, and takes it again before returning. A wait
	 * can also end spuriously: check the state it waits for in a loop.
	 */
	public function wait():Void
		_ = condition.wait();

	/** As `wait`, giving up after `timeout` seconds: whether it was woken before then. */
	public function timedWait(timeout:Float):Bool
		return condition.wait(Math.max(0, timeout));
}
#end
