package runtime.memory;

/** Condition variable whose wait operations require its own lock to be held. */
abstract ConditionVariable(hl.Abstract<"hl_condition">) {
	public static inline function create():ConditionVariable
		return cast ConditionVariableNative.native_condition_alloc();

	public inline function acquire():Void
		ConditionVariableNative.native_condition_acquire(cast this);

	public inline function tryAcquire():Bool
		return ConditionVariableNative.native_condition_try_acquire(cast this);

	public inline function release():Void
		ConditionVariableNative.native_condition_release(cast this);

	public inline function wait():Void
		ConditionVariableNative.native_condition_wait(cast this);

	public inline function timedWait(timeoutSeconds:Float):Bool
		return ConditionVariableNative.native_condition_timed_wait(cast this, timeoutSeconds);

	public inline function signal():Void
		ConditionVariableNative.native_condition_signal(cast this);

	public inline function broadcast():Void
		ConditionVariableNative.native_condition_broadcast(cast this);

	public inline function close():Void
		ConditionVariableNative.native_condition_close(cast this);
}

@:hlNative("haxeon_runtime")
private class ConditionVariableNative {
	public static function native_condition_alloc():hl.Abstract<"hl_condition">
		return null;

	public static function native_condition_acquire(condition:hl.Abstract<"hl_condition">):Void {}

	public static function native_condition_try_acquire(condition:hl.Abstract<"hl_condition">):Bool
		return false;

	public static function native_condition_release(condition:hl.Abstract<"hl_condition">):Void {}

	public static function native_condition_wait(condition:hl.Abstract<"hl_condition">):Void {}

	public static function native_condition_timed_wait(condition:hl.Abstract<"hl_condition">, timeoutSeconds:Float):Bool
		return false;

	public static function native_condition_signal(condition:hl.Abstract<"hl_condition">):Void {}

	public static function native_condition_broadcast(condition:hl.Abstract<"hl_condition">):Void {}

	public static function native_condition_close(condition:hl.Abstract<"hl_condition">):Void {}
}
