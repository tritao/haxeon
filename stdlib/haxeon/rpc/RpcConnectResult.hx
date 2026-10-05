package haxeon.rpc;

/** Opened transfers transport ownership. Adapters classify connection failures. */
enum RpcConnectResult {
	Opened(transport:MessageTransport);
	Failed(error:RpcError, retryable:Bool);
}
