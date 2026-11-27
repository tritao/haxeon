package haxeon.rpc;

/** Cancels pending work; after completion it must not close the transferred transport. */
interface RpcConnectAttempt {
	/** Abandons the attempt: it must not complete after, nor close a transport it already handed over. */
	function cancel():Void;
}
