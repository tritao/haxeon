package sys.io;

import haxe.io.Bytes;

private typedef ChildProcessHandle = hl.Abstract<"realtime_child_process">;

/**
 * A child process with nonblocking pipes, independent of any window or UI initialization. Reads return a positive byte
 * count, -1 at the end, or -2 when nothing is ready; I/O errors throw, and zero-length reads and writes return zero. Call
 * `close` to release it: it kills and reaps a child still running. POSIX and Windows hosts use bounded nonblocking pipes;
 * on Windows, writes to standard input are copied to a bounded queue a native worker thread drains. `Process` is the
 * blocking interface.
 */
extern abstract ChildProcess(ChildProcessHandle) {
	/** Spawn an independent streaming process. Environment entries override inherited values. */
	@:hlNative("haxeon_runtime", "__process_spawn")
	public static function spawn(command:String, arguments:Array<String>, cwd:String = "",
			?environmentKeys:Array<String>, ?environmentValues:Array<String>, detached:Bool = false,
			newProcessGroup:Bool = true):ChildProcess;

	/**
	 * Reads up to `length` bytes of the child's standard output into `bytes` at `offset`: how many, or -1 at the end,
	 * or -2 when none are ready.
	 */
	@:hlNative("haxeon_runtime", "__child_read_stdout")
	public function readStdout(bytes:Bytes, offset:Int, length:Int):Int;

	/**
	 * Reads up to `length` bytes of the child's standard error into `bytes` at `offset`: how many, or -1 at the end, or
	 * -2 when none are ready.
	 */
	@:hlNative("haxeon_runtime", "__child_read_stderr")
	public function readStderr(bytes:Bytes, offset:Int, length:Int):Int;
	/** Returns bytes accepted (possibly partial), or zero for backpressure. */
	@:hlNative("haxeon_runtime", "__child_write")
	public function writeStdin(bytes:Bytes, offset:Int, length:Int):Int;

	/** Closes the child's standard input, so it reads its end. */
	@:hlNative("haxeon_runtime", "__child_close_stdin")
	public function closeStdin():Void;
	/** Returns -1 while running, otherwise the cached exit status (128 + signal). */
	@:hlNative("haxeon_runtime", "__child_poll_exit")
	public function pollExit():Int;
	/** Request termination without waiting. */
	@:hlNative("haxeon_runtime", "__child_cancel")
	public function cancel():Void;

	/** Releases the child: kills and reaps it when it is still running, and closes its pipes. */
	@:hlNative("haxeon_runtime", "__child_close")
	public function close():Void;
}
