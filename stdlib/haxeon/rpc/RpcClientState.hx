package haxeon.rpc;

/** Where an `RpcClient` is in connecting to its peer. */
enum RpcClientState {
	/** Not connected, waiting to try again. */
	Disconnected;

	/** Opening a transport through its connector. */
	Connecting;

	/** Exchanging the handshake over a transport that opened. */
	Handshaking;

	/** Connected: calls and notifications go through `current()`. */
	Connected;

	/** Closed by `close`; it never connects again. */
	Closed;
}
