package haxeon;

/** Named spans recorded in a HashLink diagnostics profiler capture. */
class ProfileSpan {
  static inline var SPAN_BEGIN = 0x484C1001;
  static inline var SPAN_END = 0x484C1002;

  public static function begin(name:String):Void emit(SPAN_BEGIN, name);
  public static function end(name:String):Void emit(SPAN_END, name);

  static function emit(code:Int, name:String):Void {
    nativeProfileSpan(code, name);
  }
}

@:hlNative("std", "sys_profile_span")
extern function nativeProfileSpan(code:Int, name:String):Void;
