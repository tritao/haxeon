package haxeon.rpc;

/**
 * Why an RPC call, connection or handshake failed: what a call's `Future<Result<Response, RpcError>>` settles as its
 * `Err`, and what `RpcClient.lastError` holds. A peer's own error arrives as `Remote`, with the code it chose. Where a
 * failure leaves open whether the request ran on the peer, the case says so (`mayHaveRun`): retrying such a request may
 * run it twice.
 */
enum RpcError {
	/** The connection closed, before the request was sent or, when `mayHaveRun`, while it was in flight. */
	Disconnected(mayHaveRun:Bool);

	/** Too many calls are in flight, or too many bytes wait to be sent, here or on the peer. */
	Busy;

	/** The deadline passed, before the request was sent or, when `mayHaveRun`, while it was in flight. */
	TimedOut(mayHaveRun:Bool);

	/** The peer handles no such method. */
	UnknownMethod;

	/** The peer could not decode the request. */
	InvalidRequest;

	/** The response did not decode as the method's response type; the request ran. */
	InvalidResponse;

	/** The peer's handler threw, or its future failed. */
	HandlerFailed;

	/** The peer's handler was cancelled while it worked. */
	HandlerCancelled;

	/** The peer stopped observing its handler's work. */
	HandlerStopped;

	/** The connector could not open a transport, for `reason`; `retryable` says whether trying again may succeed. */
	ConnectFailed(reason:String, retryable:Bool);

	/** The connector did not open a transport before the client's connect timeout. */
	ConnectTimeout;

	/** The handshake failed: `reason` is its code, such as `"unsupported_protocol"` or `"invalid_handshake"`. */
	HandshakeFailed(reason:String);

	/** The handshake did not finish before its deadline. */
	HandshakeTimeout;

	/** The server's authorization refused the connection, for `reason`. */
	AuthorizationFailed(reason:String);

	/** The peers share no capability `name` that one of them requires. */
	MissingCapability(name:String);

	/** The peer broke the protocol, which closed the connection: `reason` is its code, such as `"invalid_envelope"`. */
	ProtocolViolation(reason:String);

	/** `RpcClient.retryNow(true)` dropped the connection, whose network changed. */
	NetworkChanged;

	/** The client made as many connection attempts as a generation number counts. */
	GenerationExhausted;

	/** The peer's own error, as it sent it: its `code`, `message`, and whether the request may have run. */
	Remote(code:String, message:String, mayHaveRun:Bool);

	/** Whether the request may have run on the peer, so that retrying it may run it twice. */
	public function mayHaveRun():Bool
		return switch this {
			case Disconnected(ran), TimedOut(ran), Remote(_, _, ran): ran;
			case InvalidResponse, HandlerFailed, HandlerCancelled, HandlerStopped: true;
			default: false;
		}

	/** The stable code that names the failure on the wire and in logs, such as `"disconnected"` or a peer's own. */
	public function code():String
		return switch this {
			case Disconnected(_): "disconnected";
			case Busy: "busy";
			case TimedOut(_): "timeout";
			case UnknownMethod: "unknown_method";
			case InvalidRequest: "invalid_request";
			case InvalidResponse: "invalid_response";
			case HandlerFailed: "handler_failed";
			case HandlerCancelled: "cancelled";
			case HandlerStopped: "stopped";
			case ConnectFailed(_, _): "connect_failed";
			case ConnectTimeout: "connect_timeout";
			case HandshakeFailed(reason), ProtocolViolation(reason): reason;
			case HandshakeTimeout: "handshake_timeout";
			case AuthorizationFailed(_): "authorization_failed";
			case MissingCapability(_): "missing_capability";
			case NetworkChanged: "network_changed";
			case GenerationExhausted: "generation_exhausted";
			case Remote(code, _, _): code;
		}
}
