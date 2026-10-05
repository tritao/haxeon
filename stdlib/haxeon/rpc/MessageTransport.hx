package haxeon.rpc;

import haxe.io.Bytes;

/** Message boundaries are supplied by WebSocket or an incremental stream adapter.
 * Accepted send transfers immutable buffer ownership; rejected send retains it.
 * receive transfers ownership to the caller. No borrowed asynchronous buffers. */
interface MessageTransport {
	function isOpen():Bool;
	function send(message:Bytes):Bool;
	function receive():Null<Bytes>;
	function close():Void;
}
