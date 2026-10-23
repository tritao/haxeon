package haxeon;

/**
  Frame boundaries recorded in a profiler capture. A frame set's frames run from one `mark` to the next; `idle` ends the
  current frame without starting another, so time spent waiting for work is not counted as a frame.
**/
class ProfileFrame {
  /** Starts a frame in frameSet; 0 is the main frame set. */
  public static function mark(frameSet:Int = 0):Void nativeProfileFrame(0, frameSet);

  /** Ends frameSet's current frame because it is about to wait for work. */
  public static function idle(frameSet:Int = 0):Void nativeProfileFrame(1, frameSet);
}

#if wasm
// Browser builds have no HashLink profiler to record frames.
function nativeProfileFrame(kind:Int, frameSet:Int):Void {}
#else
@:hlNative("haxeon_runtime", "__sys_profile_frame")
extern function nativeProfileFrame(kind:Int, frameSet:Int):Void;
#end
