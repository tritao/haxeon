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

	/** A decoder or parser refused its input. */
	InvalidData(reason:String);

	/** A host name did not resolve. */
	HostNotFound;

	/** A connection could not be made, or broke. */
	ConnectionFailed(reason:String);

	/** A connection or a request took longer than its deadline. */
	TimedOut;

	/** The TLS handshake or a certificate check failed. */
	TlsFailed(reason:String);

	/** The peer broke the protocol (HTTP, or the transport's framing). */
	ProtocolViolation(reason:String);

	/** The connection was closed. */
	Closed;

	/** The address to listen on is already in use. */
	AddressInUse;

	/** A request was redirected more times than allowed. */
	TooManyRedirects;

	/** The proxy refused or failed the request. */
	ProxyFailed(reason:String);

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
			case HostNotFound: "host not found";
			case ConnectionFailed(reason): explained("connection failed", reason);
			case TimedOut: "timed out";
			case TlsFailed(reason): explained("TLS failed", reason);
			case ProtocolViolation(reason): explained("protocol violation", reason);
			case Closed: "closed";
			case AddressInUse: "address in use";
			case TooManyRedirects: "too many redirects";
			case ProxyFailed(reason): explained("proxy failed", reason);
			case Failed(code, reason): explained('failed ($code)', reason);
		}

	static function explained(what:String, reason:String):String
		return reason.length == 0 ? what : '$what: $reason';
}
