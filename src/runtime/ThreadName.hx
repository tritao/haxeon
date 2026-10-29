package runtime;

/** Names the calling thread for debuggers, crash dumps and profiler captures, whichever compiler built the program. */
class ThreadName {
	public static function setCurrent(name:String):Void {
		#if haxeon
		haxeon.Threads.nameCurrent(name);
		#elseif (hl && target.threaded)
		sys.thread.Thread.current().setName(name);
		#end
	}
}
