package haxeon;

/** Program-defined counters recorded in a HashLink diagnostics profiler capture; each name becomes its own counter track. */
class ProfileCounter {
  static inline var COUNTER = 0x484C1003;

  public static function set(name:String, value:Float):Void {
    nativeProfileCounter(COUNTER, name, value);
  }
}

#if wasm
// Browser builds have no HashLink profiler to record counters.
function nativeProfileCounter(code:Int, name:String, value:Float):Void {}
#else
@:hlNative("haxeon_runtime", "__sys_profile_counter")
extern function nativeProfileCounter(code:Int, name:String, value:Float):Void;
#end
