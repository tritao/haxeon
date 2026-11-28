package std.thread;

#if wasm
#error "std.thread is not available on Wasm: a Wasm module runs on one thread"
#end

/**
 * A condition variable with its own recursive lock: a thread holding the lock waits until another signals, for a change
 * to the state the lock guards.
 */
class Condition {
	final handle:hl.Abstract<"hl_condition">;

	/** A condition with its own lock, not held. */
	public function new()
		handle = nativeConditionAlloc();

	/** Takes the lock, waiting while another thread holds it. A thread may take it again; each take needs its `release`. */
	public function acquire():Void
		nativeConditionAcquire(handle);

	/** Gives back the lock once. */
	public function release():Void
		nativeConditionRelease(handle);

	/** Wakes one thread waiting in `wait`, if any. */
	public function signal():Void
		nativeConditionSignal(handle);

	/** Wakes every thread waiting in `wait`. */
	public function broadcast():Void
		nativeConditionBroadcast(handle);

	/**
	 * With the lock held, gives it back, waits for a `signal` or `broadcast` and takes the lock again: whether it was
	 * woken, or gave up after `timeoutSeconds` (negative: without limit). A wait can also end spuriously, so check the
	 * state it waits for in a loop.
	 */
	public function wait(timeoutSeconds:Float = -1):Bool {
		if (timeoutSeconds < 0) {
			nativeConditionWait(handle);
			return true;
		}
		return nativeConditionTimedWait(handle, timeoutSeconds);
	}
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
