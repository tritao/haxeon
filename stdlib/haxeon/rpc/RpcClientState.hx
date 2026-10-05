package haxeon.rpc;

enum RpcClientState {
	Disconnected;
	Connecting;
	Handshaking;
	Connected;
	Closed;
}
