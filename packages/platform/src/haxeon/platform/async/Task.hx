package haxeon.platform.async;

import haxeon.platform.BindingError;
import haxeon.platform.NativeKitError;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.Result;
import nativekit.ffi.NativeKitTypes.TaskHandle;
import nativekit.ffi.NativeKitTypes.TaskState;

/** Managed owner for a native task handle; it never supplies a worker callback. */
class Task {
	final value:TaskHandle;
	var disposed:Bool = false;

	private function new(value:TaskHandle) this.value = value;

	/** Adopts a handle returned by native code or a Haxeon native trampoline. */
	public static function adopt(value:TaskHandle):Task {
		if (value == null || value.rawValue() == 0) throw BindingError.invalidArgument("Task.adopt", "Task cannot adopt an invalid handle");
		return new Task(value);
	}

	public function nativeHandle():TaskHandle {
		ensureLive();
		return value;
	}

	public function cancel():Void {
		ensureLive();
		check(NativeKit.nk_task_cancel(value), "task.cancel");
	}

	public function state():TaskState {
		ensureLive();
		return NativeKit.nk_task_get_state_checked(value);
	}

	public function dispose():Void {
		if (disposed) return;
		check(NativeKit.nk_task_destroy(value), "task.dispose");
		disposed = true;
	}

	public function isDisposed():Bool return disposed;

	function ensureLive():Void if (disposed) throw BindingError.disposed("Task.ensureLive", "Task has been disposed");

	static function check(status:Result, operation:String):Void
		if (status != Result.Ok)
			throw new NativeKitError(status, operation, NativeKit.nk_last_error());
}
