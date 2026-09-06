package runtime;

import sys.thread.Mutex;

/** Exclusive owner of one native runtime module handle. */
class LoadedModule {
	final mutex = new Mutex();
	var handle:Null<hl.Abstract<"realtime_module">>;

	@:allow(runtime.Runtime)
	function new(handle:hl.Abstract<"realtime_module">)
		this.handle = handle;

	@:allow(runtime.Runtime)
	function access<T>(operation:hl.Abstract<"realtime_module">->T):T {
		mutex.acquire();
		var current = handle;
		if (current == null) {
			mutex.release();
			throw new RuntimeError(RuntimeStatus.BadArgument, "Runtime module has been disposed");
		}
		try {
			var result = operation(current);
			mutex.release();
			return result;
		} catch (error:Dynamic) {
			mutex.release();
			throw error;
		}
	}

	@:allow(runtime.Runtime)
	function close(dispose:hl.Abstract<"realtime_module">->Void):Void {
		mutex.acquire();
		var current = handle;
		if (current == null) {
			mutex.release();
			return;
		}
		try {
			dispose(current);
			handle = null;
			mutex.release();
		} catch (error:Dynamic) {
			mutex.release();
			throw error;
		}
	}
}
