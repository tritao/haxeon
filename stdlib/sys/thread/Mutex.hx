package sys.thread;

#if wasm
/** Recursive mutex on a single-threaded target, where there is nothing to exclude. */
class Mutex {
	/** A lock no thread holds. */
	public function new() {}

	/** Takes the lock, waiting while another thread holds it. Each take needs its `release`. */
	public function acquire():Void {}

	/** Takes the lock if no other thread holds it: whether it did, without waiting. */
	public function tryAcquire():Bool
		return true;

	/** Gives back the lock once. */
	public function release():Void {}
}
#else
/** A recursive lock: one thread holds it at a time, and the thread holding it may take it again (`std.thread.Mutex`). */
class Mutex {
	final mutex = new std.thread.Mutex();

	/** A lock no thread holds. */
	public function new() {}

	/** Takes the lock, waiting while another thread holds it. Each take needs its `release`. */
	public function acquire():Void
		mutex.acquire();

	/** Takes the lock if no other thread holds it: whether it did, without waiting. */
	public function tryAcquire():Bool
		return mutex.tryAcquire();

	/** Gives back the lock once. */
	public function release():Void
		mutex.release();
}
#end
