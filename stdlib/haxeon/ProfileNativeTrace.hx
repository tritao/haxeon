package haxeon;

/**
  Records a native library's trace points in profiler captures: its zones become spans and its dequeued inputs become
  input events. The library implements NativeKit's trace-sink ABI (`nativekit_trace.h`) and must already be loaded
  through the FFI, which any call into it does. While no session records, the library's trace points call nothing.
**/
class ProfileNativeTrace {
  /** Returns false when `library` is not loaded or has no trace sink. */
  public static function install(library:String):Bool {
    return nativeTraceInstall(library);
  }
}

#if wasm
// Browser builds have no HashLink profiler to record native trace points.
function nativeTraceInstall(library:String):Bool {
  return false;
}
#else
@:hlNative("haxeon_runtime", "native_trace_install")
extern function nativeTraceInstall(library:String):Bool;
#end
