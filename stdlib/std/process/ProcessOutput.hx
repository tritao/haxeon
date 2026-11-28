package std.process;

#if wasm
#error "std.process is not available on Wasm: a Wasm module cannot start processes"
#end
import haxe.io.Bytes;

/** What a finished child wrote, and how it exited: `Command.output` and `Child.waitForOutput` answer it. */
class ProcessOutput {
	/** How the child exited. */
	public final status:ExitStatus;

	/** All it wrote to its standard output. */
	public final stdout:Bytes;

	/** All it wrote to its standard error. */
	public final stderr:Bytes;

	internal function new(status:ExitStatus, stdout:Bytes, stderr:Bytes) {
		this.status = status;
		this.stdout = stdout;
		this.stderr = stderr;
	}

	/** Whether the child exited with code 0. */
	public function succeeded():Bool
		return status.succeeded();

	/** Its standard output as UTF-8 text. */
	public function stdoutText():String
		return stdout.toString();

	/** Its standard error as UTF-8 text. */
	public function stderrText():String
		return stderr.toString();
}
