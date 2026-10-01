package sys.thread;

#if wasm
/** Recursive mutex on a single-threaded target, where there is nothing to exclude. */
class Mutex {
	public function new() {}

	public function acquire():Void {}

	public function tryAcquire():Bool
		return true;

	public function release():Void {}
}
#else
/** Recursive mutex backed by HashLink's standard threading primitives. */
class Mutex {
	final handle:hl.Abstract<"hl_mutex">;

	public function new()
		handle = nativeMutexAlloc(true);

	public function acquire():Void
		nativeMutexAcquire(handle);

	public function tryAcquire():Bool
		return nativeMutexTryAcquire(handle);

	public function release():Void
		nativeMutexRelease(handle);
}

@:hlNative("std", "mutex_alloc")
extern function nativeMutexAlloc(gcThread:Bool):hl.Abstract<"hl_mutex">;
@:hlNative("std", "mutex_acquire")
extern function nativeMutexAcquire(mutex:hl.Abstract<"hl_mutex">):Void;
@:hlNative("std", "mutex_try_acquire")
extern function nativeMutexTryAcquire(mutex:hl.Abstract<"hl_mutex">):Bool;
@:hlNative("std", "mutex_release")
extern function nativeMutexRelease(mutex:hl.Abstract<"hl_mutex">):Void;
#end
