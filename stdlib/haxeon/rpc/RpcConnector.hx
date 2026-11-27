package haxeon.rpc;

/** How an `RpcClient` opens a transport to its peer, once for each connection it makes. */
interface RpcConnector {
	/**
	 * Opens a transport and calls `complete` with it, which then belongs to the client, or with why it could not:
	 * usually `ConnectFailed(reason, retryable)`, whose `retryable` says whether trying again may succeed. May complete
	 * synchronously. Late completion after cancellation is fenced by the client.
	 */
	function connect(complete:Result<MessageTransport, RpcError>->Void):RpcConnectAttempt;
}
