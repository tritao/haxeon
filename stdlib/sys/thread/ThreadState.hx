package sys.thread;

#if wasm
/**
 * Which thread is running on a single-threaded target: 0 is the program's own, and `Thread.create` gives its closure a
 * number of its own while it runs, so thread-local values stay separate. Not part of the Haxe API; Thread and Tls use it.
 */
class ThreadState {
	public static var current = 0;
	static var created = 0;

	public static function enter():Int {
		var previous = current;
		current = ++created;
		return previous;
	}

	public static function leave(previous:Int):Void {
		current = previous;
	}
}
#end
