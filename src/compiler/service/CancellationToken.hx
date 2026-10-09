package compiler.service;

/** Cooperative cancellation shared by compiler and editor-service requests. */
class CancellationToken {
	public var cancelled(get, never):Bool;

	var requested:Bool = false;
	#if (target.threaded && !eval)
	final mutex = new sys.thread.Mutex();
	#end

	function get_cancelled():Bool {
		#if (target.threaded && !eval)
		mutex.acquire();
		#end
		var value = requested;
		#if (target.threaded && !eval)
		mutex.release();
		#end
		return value;
	}

	public function new() {}

	public function cancel():Void {
		#if (target.threaded && !eval)
		mutex.acquire();
		#end
		requested = true;
		#if (target.threaded && !eval)
		mutex.release();
		#end
	}

	public function check():Void {
		if (cancelled)
			throw new CancellationError();
	}
}
