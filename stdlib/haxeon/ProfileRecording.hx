package haxeon;

/**
  Starts and pauses recording within a profiling session, so a capture can hold just the moments that matter. A
  session started with `haxeon run --profile-start=manual` records nothing until `start` is called. Calls made while
  recording is paused are not recorded; calls that span a pause end at it in the trace.

  Every function returns false, and does nothing, when no profiling session is open.
**/
class ProfileRecording {
  /** Starts (or resumes) recording. */
  public static function start():Bool
    return nativeSetRecording(true);

  /** Pauses recording; the session stays open. */
  public static function pause():Bool
    return nativeSetRecording(false);

  /** Starts recording when it is paused and pauses it when it records. */
  public static function toggle():Bool
    return nativeSetRecording(!nativeRecording());

  /** Whether the session records now. */
  public static function recording():Bool
    return nativeRecording();
}

#if wasm
// Browser builds have no HashLink profiler.
function nativeSetRecording(on:Bool):Bool return false;
function nativeRecording():Bool return false;
#else
@:hlNative("std", "prof_recording_set")
extern function nativeSetRecording(on:Bool):Bool;

@:hlNative("std", "prof_recording_get")
extern function nativeRecording():Bool;
#end
