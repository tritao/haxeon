package haxeon.platform;

/**
 * Why a network operation failed: an HTTP request or a transport's connection. It reaches a caller as
 * `NativeKitError.Network`; a cancelled request is `Cancelled`, a transport that would block `Busy`, and a response
 * or message over its limit `TooLarge`, as for any other NativeKit call.
 */
enum NetworkError {
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

	/** The failure in a few words, with NativeKit's explanation where it gave one. */
	public function describe():String
		return switch this {
			case HostNotFound: "host not found";
			case ConnectionFailed(reason): explained("connection failed", reason);
			case TimedOut: "timed out";
			case TlsFailed(reason): explained("TLS failed", reason);
			case ProtocolViolation(reason): explained("protocol violation", reason);
			case Closed: "closed";
			case AddressInUse: "address in use";
			case TooManyRedirects: "too many redirects";
			case ProxyFailed(reason): explained("proxy failed", reason);
		}

	static function explained(what:String, reason:String):String
		return reason.length == 0 ? what : '$what: $reason';
}
