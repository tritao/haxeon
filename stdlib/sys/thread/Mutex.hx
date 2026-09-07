package sys.thread;

/** Recursive mutex backed by HashLink's standard threading primitives. */
abstract Mutex(hl.Abstract<"hl_mutex">) {
	public function new() {
		this = Mutex.alloc(true);
	}

	@:hlNative("std", "mutex_acquire")
	public function acquire():Void {}

	@:hlNative("std", "mutex_try_acquire")
	public function tryAcquire():Bool
		return false;

	@:hlNative("std", "mutex_release")
	public function release():Void {}

	@:hlNative("std", "mutex_alloc")
	static function alloc(gcThread:Bool):hl.Abstract<"hl_mutex">
		return null;
}
