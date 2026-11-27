package haxeon.rpc;

/** Opened transfers transport ownership. Adapters classify connection failures. */
enum RpcConnectResult {
	/** The connection opened: `transport` now belongs to the client. */
	Opened(transport:MessageTransport);

	/** The connection failed with `error`; `retryable` says whether trying again may succeed. */
	Failed(error:RpcError, retryable:Bool);
}
