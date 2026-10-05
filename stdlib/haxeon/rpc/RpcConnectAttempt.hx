package haxeon.rpc;

/** Cancels pending work; after completion it must not close the transferred transport. */
interface RpcConnectAttempt {
	function cancel():Void;
}
