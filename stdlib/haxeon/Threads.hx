package haxeon;

import sys.thread.Thread;

/**
  Named threads. Debuggers, crash dumps and profiler captures show a thread by its name, so every thread a program starts
  should have one that says what it does ("exo.git.reader"). Linux keeps the first 15 bytes.
**/
class Threads {
  /** Starts a thread named name that runs call. */
  public static function create(name:String, call:Void->Void):Thread {
    return Thread.create(function() {
      nameCurrent(name);
      call();
    });
  }

  /** Names the calling thread. */
  public static function nameCurrent(name:String):Void nativeThreadName(name);
}

#if wasm
// Browser builds run threads inline, on the one thread there is.
function nativeThreadName(name:String):Void {}
#else
@:hlNative("haxeon_runtime", "__sys_thread_set_name")
extern function nativeThreadName(name:String):Void;
#end
