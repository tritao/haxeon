package std.thread;

#if wasm
#error "std.thread is not available on Wasm: a Wasm module runs on one thread"
#end
import std.thread.Semaphore.monotonicTime;

/**
 * A thread running a function, started by `spawn` under a name that debuggers, crash dumps and profiler captures show
 * (say what it does, as `"exo.git.reader"`; Linux keeps the first 15 bytes). `join` waits for it to finish and answers
 * what the function returned. A function that throws is a bug: its thread ends with the exception printed, as any
 * uncaught exception is, and `join` throws it again.
 */
class Thread<T> {
	/** The name it was started with. */
	public final name:String;

	final finished = new Condition();
	/** The function the thread runs, until it starts running it. */
	var run:Null<Void->T>;
	var done = false;
	var result:T;
	var failed = false;
	var failure:Dynamic = null;

	function new(name:String, run:Void->T) {
		this.name = name;
		this.run = run;
	}

	/** Starts a thread named `name` running `run`; it ends when `run` returns. */
	public static function spawn<T>(name:String, run:Void->T):Thread<T> {
		if (name == null || name.length == 0 || run == null)
			throw new haxe.Exception("std.thread.Thread.spawn takes a name and a function");
		var thread = new Thread<T>(name, run);
		nativeThreadCreate(thread.body);
		return thread;
	}

	/** Names the calling thread, one this program did not start with `spawn` (a native library's callback thread). */
	public static function nameCurrent(name:String):Void
		nativeThreadName(name);

	/** Waits until the thread finishes, and answers what its function returned; throws what it threw. */
	public function join():T {
		finished.acquire();
		defer finished.release();
		while (!done)
			finished.wait();
		if (failed)
			throw failure;
		return result;
	}

	/** Waits up to `timeoutSeconds` (negative: without limit) for the thread to finish: whether it has. */
	public function wait(timeoutSeconds:Float):Bool {
		finished.acquire();
		defer finished.release();
		if (timeoutSeconds < 0) {
			while (!done)
				finished.wait();
			return true;
		}
		// The clock a wait is measured on must not move with the system's time.
		var deadline = monotonicTime() + timeoutSeconds;
		while (!done) {
			var remaining = deadline - monotonicTime();
			if (remaining <= 0)
				return false;
			finished.wait(remaining);
		}
		return true;
	}

	/** Whether the thread has finished, without waiting. */
	public function isFinished():Bool {
		finished.acquire();
		defer finished.release();
		return done;
	}

	function body():Void {
		nativeThreadName(name);
		var call = run;
		run = null;
		if (call == null)
			throw new haxe.Exception("std.thread.Thread runs its function once");
		var value:T;
		try {
			value = call();
		} catch (error:Dynamic) {
			finish(() -> {
				failed = true;
				failure = error;
			});
			// Uncaught, so the runtime prints it where it happened.
			throw error;
		}
		finish(() -> result = value);
	}

	function finish(record:Void->Void):Void {
		finished.acquire();
		defer finished.release();
		record();
		done = true;
		finished.broadcast();
	}
}

@:hlNative("std", "thread_create")
internal extern function nativeThreadCreate(run:Void->Void):hl.Abstract<"hl_thread">;

@:hlNative("haxeon_runtime", "__sys_thread_set_name")
internal extern function nativeThreadName(name:String):Void;
