package sys.thread;

#if wasm
/**
 * A thread on a single-threaded target runs its closure to completion when it is created, before `create` returns, so the
 * program sees the effects a started thread would eventually have. Anything the closure waits for from the creating
 * code (a `Lock` released later, say) can never come, and reports that instead of hanging.
 */
class Thread {
	function new() {}

	/** Starts a thread running `call`. The thread ends when `call` returns. */
	public static function create(call:Void->Void):Thread {
		var previous = ThreadState.enter();
		defer ThreadState.leave(previous);
		call();
		return new Thread();
	}
}
#else
/** Haxe's thread: a `std.thread.Thread` named "sys.thread", as Haxe's threads have no names. */
class Thread {
	final thread:std.thread.Thread<Void>;

	function new(thread:std.thread.Thread<Void>)
		this.thread = thread;

	/** Starts a thread running `call`. The thread ends when `call` returns. */
	public static function create(call:Void->Void):Thread
		return new Thread(std.thread.Thread.spawn("sys.thread", call));
}
#end
