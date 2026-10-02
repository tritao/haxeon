package sys.thread;

#if wasm
/**
 * Condition variable on a single-threaded target: no other thread can signal, so a wait that has to wait never ends.
 * `wait` says so instead of hanging; `timedWait` times out at once.
 */
class Condition {
  public function new() {}

  public function acquire():Void {}
  public function release():Void {}
  public function signal():Void {}
  public function broadcast():Void {}
  public function wait():Void throw "Condition.wait would block forever on a single-threaded target";
  public function timedWait(timeout:Float):Bool return false;
}
#else
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
#end
