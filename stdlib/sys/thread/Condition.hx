package sys.thread;

/** Recursive mutex and condition variable backed by HashLink. */
class Condition {
  final handle:hl.Abstract<"hl_condition">;

  public function new() handle = nativeConditionAlloc();

  public function acquire():Void nativeConditionAcquire(handle);
  public function release():Void nativeConditionRelease(handle);
  public function signal():Void nativeConditionSignal(handle);
  public function broadcast():Void nativeConditionBroadcast(handle);
  public function wait():Void nativeConditionWait(handle);
  public function timedWait(timeout:Float):Bool return nativeConditionTimedWait(handle, timeout);
}

@:hlNative("std", "condition_alloc")
extern function nativeConditionAlloc():hl.Abstract<"hl_condition">;
@:hlNative("std", "condition_acquire")
extern function nativeConditionAcquire(condition:hl.Abstract<"hl_condition">):Void;
@:hlNative("std", "condition_release")
extern function nativeConditionRelease(condition:hl.Abstract<"hl_condition">):Void;
@:hlNative("std", "condition_signal")
extern function nativeConditionSignal(condition:hl.Abstract<"hl_condition">):Void;
@:hlNative("std", "condition_broadcast")
extern function nativeConditionBroadcast(condition:hl.Abstract<"hl_condition">):Void;
@:hlNative("std", "condition_wait")
extern function nativeConditionWait(condition:hl.Abstract<"hl_condition">):Void;
@:hlNative("std", "condition_timed_wait")
extern function nativeConditionTimedWait(condition:hl.Abstract<"hl_condition">, timeout:Float):Bool;
