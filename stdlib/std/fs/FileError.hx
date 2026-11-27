package std.fs;

/**
 * Why a `std.fs` operation failed: what its `Result` holds as its `Err`. The cases name the failures a caller handles
 * apart; anything else the system reports is `Io`, with the system's own code and message.
 */
enum FileError {
	/** Nothing is at the path, or a directory on the way to it is missing. */
	NotFound;

	/** Something is already at the path, where the operation creates one. */
	AlreadyExists;

	/** The directory has entries, where the operation needs it empty. */
	NotEmpty;

	/** The path, or a part of the way to it, is not a directory, where the operation needs one. */
	NotADirectory;

	/** The path is a directory, where the operation needs a file. */
	IsADirectory;

	/** The system refused the operation: permissions, a read-only filesystem, or a file another process holds. */
	PermissionDenied;

	/** The path leads out of the `Root` it was resolved in, through `..` or a symbolic link. */
	EscapesRoot;

	/** This system cannot do the operation as asked, such as confined resolution on a kernel without it. */
	Unsupported;

	/** Another failure: the system's `code` (`errno`, or `GetLastError` on Windows) and its `message`. */
	Io(code:Int, message:String);

	/** The failure in a few words, for a message: `"not found"`, or an `Io`'s own message. */
	public function describe():String
		return switch this {
			case NotFound: "not found";
			case AlreadyExists: "already exists";
			case NotEmpty: "directory not empty";
			case NotADirectory: "not a directory";
			case IsADirectory: "is a directory";
			case PermissionDenied: "permission denied";
			case EscapesRoot: "escapes the root";
			case Unsupported: "not supported";
			case Io(_, message): message;
		}
}
