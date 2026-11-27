package haxeon.platform;

/**
 * Why NativeKit could not do what the environment decides: no such feature or device, nothing there, the network or
 * the user refusing. It is what an operation's `Result` holds as its `Err`, and what a `NativeKitException` carries
 * where an API throws instead. A failure that is the program's mistake (a bad argument or handle, the wrong thread)
 * is not one of these: it throws a `BindingError`. `reason` is NativeKit's own explanation, empty when it gave none.
 */
enum NativeKitError {
	/** This system, backend or build cannot do it. */
	Unsupported(reason:String);

	/** What was asked for is not there. */
	NotFound;

	/** The user or the system refused. */
	PermissionDenied(reason:String);

	/** The operation was cancelled before it finished. */
	Cancelled;

	/** NativeKit cannot take more now (its queue is full, or a socket would block); trying again later may succeed. */
	Busy;

	/** The data is larger than NativeKit takes or keeps. */
	TooLarge;

	/** NativeKit ran out of memory. */
	OutOfMemory;

	/** The surface was lost, as when its window closed or its device was reset. */
	SurfaceLost;

	/** The content given is malformed, or in a format the operation does not read (a decoder refused it). */
	InvalidData(reason:String);

	/** A network operation failed: an HTTP request or a transport's connection. */
	Network(error:NetworkError);

	/** Any other failure: NativeKit's result `code` and its explanation. */
	Failed(code:Int, reason:String);

	/** The failure in a few words, with NativeKit's explanation where it gave one. */
	public function describe():String
		return switch this {
			case Unsupported(reason): explained("not supported", reason);
			case NotFound: "not found";
			case PermissionDenied(reason): explained("permission denied", reason);
			case Cancelled: "cancelled";
			case Busy: "busy";
			case TooLarge: "too large";
			case OutOfMemory: "out of memory";
			case SurfaceLost: "surface lost";
			case InvalidData(reason): explained("invalid data", reason);
			case Network(error): error.describe();
			case Failed(code, reason): explained('failed ($code)', reason);
		}

	static function explained(what:String, reason:String):String
		return reason.length == 0 ? what : '$what: $reason';
}
