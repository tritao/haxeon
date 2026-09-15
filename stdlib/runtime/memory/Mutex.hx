package runtime.memory;

/** Recursive runtime mutex backed by HashLink's portable thread layer. */
abstract Mutex(hl.Abstract<"hl_mutex">) {
	public static inline function create(?gcThread:Bool = false):Mutex
		return cast MutexNative.native_mutex_alloc(gcThread);

	public inline function acquire():Void
		MutexNative.native_mutex_acquire(cast this);

	public inline function tryAcquire():Bool
		return MutexNative.native_mutex_try_acquire(cast this);

	public inline function release():Void
		MutexNative.native_mutex_release(cast this);

	public inline function close():Void
		MutexNative.native_mutex_close(cast this);
}

@:hlNative("haxeon_runtime")
private class MutexNative {
	public static function native_mutex_alloc(gcThread:Bool):hl.Abstract<"hl_mutex">
		return null;

	public static function native_mutex_acquire(mutex:hl.Abstract<"hl_mutex">):Void {}

	public static function native_mutex_try_acquire(mutex:hl.Abstract<"hl_mutex">):Bool
		return false;

	public static function native_mutex_release(mutex:hl.Abstract<"hl_mutex">):Void {}

	public static function native_mutex_close(mutex:hl.Abstract<"hl_mutex">):Void {}
}
