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
/** A condition variable with its own recursive lock: threads wait on it, with the lock held, until another signals. */
class Condition {
	final handle:hl.Abstract<"hl_condition">;

	/** A condition with its own lock, not held. */
	public function new() handle = nativeConditionAlloc();

	/**
	 * Takes the lock, waiting while another thread holds it. A thread may take it again; each take needs its `release`.
	 */
	public function acquire():Void nativeConditionAcquire(handle);

	/** Gives back the lock once. */
	public function release():Void nativeConditionRelease(handle);

	/** Wakes one thread waiting in `wait` or `timedWait`, if any. */
	public function signal():Void nativeConditionSignal(handle);

	/** Wakes every thread waiting in `wait` or `timedWait`. */
	public function broadcast():Void nativeConditionBroadcast(handle);

	/**
	 * With the lock held, releases it, waits for a `signal` or `broadcast`, and takes it again before returning. A wait
	 * can also end spuriously: check the state it waits for in a loop.
	 */
	public function wait():Void nativeConditionWait(handle);

	/** As `wait`, giving up after `timeout` seconds: whether it was woken before then. */
	public function timedWait(timeout:Float):Bool return nativeConditionTimedWait(handle, timeout);
}

@:hlNative("std", "condition_alloc")
internal extern function nativeConditionAlloc():hl.Abstract<"hl_condition">;
@:hlNative("std", "condition_acquire")
internal extern function nativeConditionAcquire(condition:hl.Abstract<"hl_condition">):Void;
@:hlNative("std", "condition_release")
internal extern function nativeConditionRelease(condition:hl.Abstract<"hl_condition">):Void;
@:hlNative("std", "condition_signal")
internal extern function nativeConditionSignal(condition:hl.Abstract<"hl_condition">):Void;
@:hlNative("std", "condition_broadcast")
internal extern function nativeConditionBroadcast(condition:hl.Abstract<"hl_condition">):Void;
@:hlNative("std", "condition_wait")
internal extern function nativeConditionWait(condition:hl.Abstract<"hl_condition">):Void;
@:hlNative("std", "condition_timed_wait")
internal extern function nativeConditionTimedWait(condition:hl.Abstract<"hl_condition">, timeout:Float):Bool;
#end
