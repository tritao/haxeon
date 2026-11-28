package std.process;

#if wasm
#error "std.process is not available on Wasm: a Wasm module cannot start processes"
#end
/** How a child ended. */
enum ExitStatus {
	/** It exited with `code`: 0 for success, by convention. On Windows every child ends this way. */
	Exited(code:Int);

	/** A signal ended it (POSIX), such as 15 for SIGTERM after `terminate` or 9 for SIGKILL after `kill`. */
	Signaled(signal:Int);

	/** Whether it exited with code 0. */
	public function succeeded():Bool
		return this.match(Exited(0));

	/** How it ended, in a few words: `"exit code 1"`, `"signal 9"`. */
	public function describe():String
		return switch this {
			case Exited(code): 'exit code $code';
			case Signaled(signal): 'signal $signal';
		}
}
