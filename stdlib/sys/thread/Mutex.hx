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
/** A recursive lock: one thread holds it at a time, and the thread holding it may take it again. */
class Mutex {
	final handle:hl.Abstract<"hl_mutex">;

	/** A lock no thread holds. */
	public function new()
		handle = nativeMutexAlloc(true);

	/** Takes the lock, waiting while another thread holds it. Each take needs its `release`. */
	public function acquire():Void
		nativeMutexAcquire(handle);

	/** Takes the lock if no other thread holds it: whether it did, without waiting. */
	public function tryAcquire():Bool
		return nativeMutexTryAcquire(handle);

	/** Gives back the lock once. */
	public function release():Void
		nativeMutexRelease(handle);
}

@:hlNative("std", "mutex_alloc")
internal extern function nativeMutexAlloc(gcThread:Bool):hl.Abstract<"hl_mutex">;
@:hlNative("std", "mutex_acquire")
internal extern function nativeMutexAcquire(mutex:hl.Abstract<"hl_mutex">):Void;
@:hlNative("std", "mutex_try_acquire")
internal extern function nativeMutexTryAcquire(mutex:hl.Abstract<"hl_mutex">):Bool;
@:hlNative("std", "mutex_release")
internal extern function nativeMutexRelease(mutex:hl.Abstract<"hl_mutex">):Void;
#end
