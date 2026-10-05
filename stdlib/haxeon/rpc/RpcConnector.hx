package haxeon.rpc;

interface RpcConnector {
	/** May complete synchronously. Late completion after cancellation is fenced by the client. */
	function connect(complete:RpcConnectResult->Void):RpcConnectAttempt;
}
