package runtime;

import sys.thread.Mutex;

/** Exclusive owner of one native runtime module handle. */
class LoadedModule {
	final mutex = new Mutex();
	var handle:Null<hl.Abstract<"realtime_module">>;
	var closeRequested = false;
	var borrowers = 0;
	var deferredDispose:Null<hl.Abstract<"realtime_module">->Void>;

	@:allow(runtime.Runtime)
	function new(handle:hl.Abstract<"realtime_module">)
		this.handle = handle;

	@:allow(runtime.Runtime)
	function access<T>(operation:hl.Abstract<"realtime_module">->T):T {
		mutex.acquire();
		var current = handle;
		if (current == null || closeRequested) {
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
	function accessRetained(operation:hl.Abstract<"realtime_module">->Dynamic):Dynamic {
		mutex.acquire();
		var current = handle;
		if (current == null || closeRequested) {
			mutex.release();
			throw new RuntimeError(RuntimeStatus.BadArgument, "Runtime module has been disposed");
		}
		try {
			var result = operation(current);
			borrowers++;
			mutex.release();
			return result;
		} catch (error:Dynamic) {
			mutex.release();
			throw error;
		}
	}

	@:allow(runtime.RetainedValue)
	function accessBorrowed<T>(operation:hl.Abstract<"realtime_module">->T):T {
		mutex.acquire();
		var current = handle;
		if (current == null || borrowers <= 0) {
			mutex.release();
			throw new RuntimeError(RuntimeStatus.BadArgument, "Retained runtime module is unavailable");
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

	@:allow(runtime.RetainedValue)
	function release():Void {
		mutex.acquire();
		if (borrowers <= 0) {
			mutex.release();
			throw new RuntimeError(RuntimeStatus.BadArgument, "Runtime module borrow count is invalid");
		}
		borrowers--;
		if (borrowers == 0 && closeRequested) {
			var current = handle, dispose = deferredDispose;
			if (current != null && dispose != null) {
				try {
					dispose(current);
					handle = null;
					deferredDispose = null;
				} catch (error:RuntimeError) {
					if (error.status == RuntimeStatus.RetirementBlocked) {
						mutex.release();
						return;
					}
					mutex.release();
					throw error;
				} catch (error:Dynamic) {
					mutex.release();
					throw error;
				}
			}
		}
		mutex.release();
	}

	@:allow(runtime.Runtime)
	function close(dispose:hl.Abstract<"realtime_module">->Void):Bool {
		mutex.acquire();
		var current = handle;
		if (current == null) {
			mutex.release();
			return true;
		}
		closeRequested = true;
		if (borrowers > 0) {
			deferredDispose = dispose;
			mutex.release();
			return false;
		}
		try {
			dispose(current);
			handle = null;
			mutex.release();
			return true;
		} catch (error:RuntimeError) {
			if (error.status == RuntimeStatus.RetirementBlocked) {
				mutex.release();
				return false;
			}
			mutex.release();
			throw error;
		} catch (error:Dynamic) {
			mutex.release();
			throw error;
		}
	}
}
