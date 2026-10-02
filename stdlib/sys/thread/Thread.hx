package sys.thread;

#if wasm
/**
 * A thread on a single-threaded target runs its closure to completion when it is created, before `create` returns, so the
 * program sees the effects a started thread would eventually have. Anything the closure waits for from the creating
 * code (a `Lock` released later, say) can never come, and reports that instead of hanging.
 */
class Thread {
	function new() {}

	public static function create(call:Void->Void):Thread {
		var previous = ThreadState.enter();
		try {
			call();
		} catch (error:Dynamic) {
			ThreadState.leave(previous);
			throw error;
		}
		ThreadState.leave(previous);
		return new Thread();
	}
}
#else
/** A garbage-collected HashLink thread running a zero-argument closure. */
extern abstract Thread(hl.Abstract<"hl_thread">) {
	@:hlNative("std", "thread_create")
	public static function create(call:Void->Void):Thread;
}
#end
