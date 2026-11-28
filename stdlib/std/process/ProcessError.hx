package std.process;

#if wasm
#error "std.process is not available on Wasm: a Wasm module cannot start processes"
#end
/**
 * Why a `std.process` operation failed: what its `Result` holds as its `Err`. The cases name the failures a caller
 * handles apart; anything else the system reports is `Io`, with the system's own code and message.
 */
enum ProcessError {
	/** The program is not there: no such file, or none of that name on the `PATH`. */
	NotFound;

	/** The system refused to run the program, or to enter its working directory. */
	PermissionDenied;

	/** The working directory given to the command is not a directory. */
	DirectoryNotFound;

	/** The child no longer reads its input: it closed it, or exited. */
	InputClosed;

	/** The wait ran out of time first. */
	TimedOut;

	/** This system cannot start the command as asked, such as a working directory on an Android version without it. */
	Unsupported;

	/** Another failure: the system's `code` (`errno`, or `GetLastError` on Windows) and its `message`. */
	Io(code:Int, message:String);

	/** The failure in a few words, for a message: `"program not found"`, or an `Io`'s own message. */
	public function describe():String
		return switch this {
			case NotFound: "program not found";
			case PermissionDenied: "permission denied";
			case DirectoryNotFound: "working directory not found";
			case InputClosed: "the process no longer reads its input";
			case TimedOut: "timed out";
			case Unsupported: "not supported";
			case Io(_, message): message;
		}
}
