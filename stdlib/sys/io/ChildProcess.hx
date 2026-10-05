package sys.io;

import haxe.io.Bytes;

private typedef ChildProcessHandle = hl.Abstract<"realtime_child_process">;

/** Nonblocking pipes, independent of any window or UI initialization.
 * Reads return a positive byte count, -1 for EOF, or -2 for would-block.
 * I/O errors throw. Zero-length reads/writes return zero.
 * Call close() to release ownership; it kills and reaps a still-running child.
 * The streaming backend currently supports POSIX hosts; Windows spawn throws.
 */
extern abstract ChildProcess(ChildProcessHandle) {
	@:hlNative("haxeon_runtime", "__child_read_stdout")
	public function readStdout(bytes:Bytes, offset:Int, length:Int):Int;
	@:hlNative("haxeon_runtime", "__child_read_stderr")
	public function readStderr(bytes:Bytes, offset:Int, length:Int):Int;
	/** Returns bytes accepted (possibly partial), or zero for backpressure. */
	@:hlNative("haxeon_runtime", "__child_write")
	public function writeStdin(bytes:Bytes, offset:Int, length:Int):Int;
	@:hlNative("haxeon_runtime", "__child_close_stdin")
	public function closeStdin():Void;
	/** Returns -1 while running, otherwise the cached exit status (128 + signal). */
	@:hlNative("haxeon_runtime", "__child_poll_exit")
	public function pollExit():Int;
	/** Request termination without waiting. */
	@:hlNative("haxeon_runtime", "__child_cancel")
	public function cancel():Void;
	@:hlNative("haxeon_runtime", "__child_close")
	public function close():Void;
}
