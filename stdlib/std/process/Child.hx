package std.process;

#if wasm
#error "std.process is not available on Wasm: a Wasm module cannot start processes"
#end
import std.bytes.Bytes;
import std.bytes.BytesBuffer;
import std.process.ChildNatives;

/**
 * A running program, started by `Command.spawn`. Its piped streams are `stdin`, `stdout` and `stderr` (null for one
 * that was inherited or discarded). `wait` for it to exit, or `waitForOutput` to read what it writes as well.
 *
 * A child belongs to the `Child` that started it: `close` (or a `scoped` binding, or the collector) ends it if it still
 * runs, with what it started in its group, and reaps it, so no process outlives its owner by accident. A child started
 * `detached` is left running instead.
 */
class Child implements Disposable {
	var handle:Null<ChildHandle>;
	var status:Null<ExitStatus> = null;
	final scratch = Bytes.alloc(8);

	/** The child's process id. */
	public final pid:Int;

	/** The child's standard input, when it is piped. */
	public final stdin:Null<ChildInput>;

	/** The child's standard output, when it is piped. */
	public final stdout:Null<ChildOutput>;

	/** The child's standard error, when it is piped. */
	public final stderr:Null<ChildOutput>;

	internal function new(handle:ChildHandle, input:Stdio, output:Stdio, error:Stdio) {
		this.handle = handle;
		pid = ChildNatives.pid(handle);
		stdin = input == Pipe ? new ChildInput(this) : null;
		stdout = output == Pipe ? new ChildOutput(this, false) : null;
		stderr = error == Pipe ? new ChildOutput(this, true) : null;
	}

	/**
	 * Waits up to `timeoutSeconds` (negative: without limit) for the child to exit, and answers how it did; `TimedOut`
	 * when it still runs. Closes the child's input first, so a child reading it to its end can finish.
	 */
	public function wait(timeoutSeconds:Float = -1):Result<ExitStatus, ProcessError> {
		var known = status;
		if (known != null)
			return Ok(known);
		var input = stdin;
		if (input != null)
			input.close();
		var ready = ChildNatives.wait(live(), Readiness.Exit, ChildNatives.milliseconds(timeoutSeconds));
		if (ready < 0)
			return Err(ChildNatives.lastError());
		var exited = exitStatus();
		return exited == null ? Err(TimedOut) : Ok(exited);
	}

	/** How the child exited, without waiting: null while it runs. */
	public function exitStatus():Null<ExitStatus> {
		var known = status;
		if (known != null)
			return known;
		if (!ChildNatives.exitStatus(live(), scratch)) {
			if (ChildNatives.nativeError() != 0)
				throw new haxe.Exception("std.process.Child: the exit could not be read: "
					+ ChildNatives.lastError().describe());
			return null;
		}
		var value = scratch.getInt32(4);
		var exited = scratch.getInt32(0) == 1 ? ExitStatus.Signaled(value) : ExitStatus.Exited(value);
		status = exited;
		return exited;
	}

	/**
	 * Closes the child's input, reads its piped output and error to their ends, and waits for it to exit, all within
	 * `timeoutSeconds` (negative: without limit). An output that is not piped is empty in the answer.
	 */
	public function waitForOutput(timeoutSeconds:Float = -1):Result<ProcessOutput, ProcessError> {
		var input = stdin;
		if (input != null)
			input.close();
		var deadline = timeoutSeconds < 0 ? -1.0 : ChildNatives.monotonicTime() + timeoutSeconds;
		var output = new BytesBuffer(), error = new BytesBuffer(), chunk = Bytes.alloc(16384);
		var outputOpen = stdout != null, errorOpen = stderr != null;
		while (outputOpen || errorOpen) {
			var held = live(), progressed = false;
			if (outputOpen) {
				var got = ChildNatives.readStdout(held, chunk, 0, chunk.length);
				if (got == -3)
					return Err(ChildNatives.lastError());
				if (got == -1)
					outputOpen = false;
				else if (got > 0) {
					output.addBytes(chunk, 0, got);
					progressed = true;
				}
			}
			if (errorOpen) {
				var got = ChildNatives.readStderr(held, chunk, 0, chunk.length);
				if (got == -3)
					return Err(ChildNatives.lastError());
				if (got == -1)
					errorOpen = false;
				else if (got > 0) {
					error.addBytes(chunk, 0, got);
					progressed = true;
				}
			}
			if (progressed || !(outputOpen || errorOpen))
				continue;
			var left = remaining(deadline);
			if (left == 0)
				return Err(TimedOut);
			var wanted = (outputOpen ? (Readiness.Stdout:Int) : 0) | (errorOpen ? (Readiness.Stderr:Int) : 0);
			var ready = ChildNatives.wait(held, wanted, ChildNatives.milliseconds(left));
			if (ready < 0)
				return Err(ChildNatives.lastError());
			if (ready == 0)
				return Err(TimedOut);
		}
		var exited = try wait(remaining(deadline));
		return Ok(new ProcessOutput(exited, output.getBytes(), error.getBytes()));
	}

	/**
	 * Asks the child to stop: SIGTERM on POSIX (to its group when it has one of its own), which it may handle to clean
	 * up; on Windows it is ended at once, as `kill` does. Does nothing once it has exited.
	 */
	public function terminate():Void
		ChildNatives.signal(live(), false);

	/** Ends the child at once (SIGKILL, or ending it and what it started on Windows). Does nothing once it has exited. */
	public function kill():Void
		ChildNatives.signal(live(), true);

	/** Whether `close` has been called. */
	public function isClosed():Bool
		return handle == null;

	/**
	 * Releases the child: ends it if it still runs (unless it was started detached) and reaps it, and closes its pipes.
	 * The child cannot be used afterwards; closing it again does nothing.
	 */
	public function close():Void {
		var held = handle;
		handle = null;
		if (held != null)
			ChildNatives.close(held);
	}

	/** Closes the child, as `close` does. */
	public function dispose():Void
		close();

	internal function live():ChildHandle {
		var held = handle;
		if (held == null)
			throw new haxe.Exception("std.process.Child is closed");
		return held;
	}

	/** The seconds left before `deadline` (negative: without limit), never below 0. */
	static function remaining(deadline:Float):Float
		return deadline < 0 ? -1.0 : Math.max(0, deadline - ChildNatives.monotonicTime());
}
