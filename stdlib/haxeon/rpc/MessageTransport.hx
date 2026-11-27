package haxeon.rpc;

import haxe.io.Bytes;

/** Message boundaries are supplied by WebSocket or an incremental stream adapter.
 * Accepted send transfers immutable buffer ownership; rejected send retains it.
 * receive transfers ownership to the caller. No borrowed asynchronous buffers. */
interface MessageTransport {
	/** Whether messages can still be sent and received. */
	function isOpen():Bool;

	/** Sends `message` whole: true when the transport took it (and owns it now), false when it is closed or full. */
	function send(message:Bytes):Bool;

	/** The next message received, whole, or null when none is waiting. The caller owns it. */
	function receive():Null<Bytes>;

	/** Closes the transport; nothing is sent or received after. */
	function close():Void;
}
