package haxeon.rpc;

/** How an `RpcClient` opens a transport to its peer, once for each connection it makes. */
interface RpcConnector {
	/** May complete synchronously. Late completion after cancellation is fenced by the client. */
	function connect(complete:RpcConnectResult->Void):RpcConnectAttempt;
}
