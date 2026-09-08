package sys.thread;

/** A garbage-collected HashLink thread running a zero-argument closure. */
extern abstract Thread(hl.Abstract<"hl_thread">) {
	@:hlNative("std", "thread_create")
	public static function create(call:Void->Void):Thread;
}
