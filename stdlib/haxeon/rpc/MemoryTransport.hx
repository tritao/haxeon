package haxeon.rpc;

import haxe.io.Bytes;

/** Bounded deterministic message channel with explicit loss injection. */
class MemoryTransport implements MessageTransport {
	final maxBytes:Int;
	final maxMessages:Int;
	final incoming:Array<Bytes> = [];
	var queuedBytes:Int = 0;
	var open:Bool = true;
	var peer:Null<MemoryTransport>;
	var dropNext:Bool = false;

	private function new(maxBytes:Int, maxMessages:Int) {
		if (maxBytes < 1 || maxMessages < 1)
			throw "Invalid memory transport limits";
		this.maxBytes = maxBytes;
		this.maxMessages = maxMessages;
	}

	public static function pair(maxBytes:Int = 8 * 1024 * 1024, maxMessages:Int = 256):{client:MemoryTransport, server:MemoryTransport} {
		var client = new MemoryTransport(maxBytes, maxMessages);
		var server = new MemoryTransport(maxBytes, maxMessages);
		client.peer = server;
		server.peer = client;
		return {client: client, server: server};
	}

	/** The next accepted message disappears after send reports success. */
	public function loseNext():Void
		dropNext = true;

	public function isOpen():Bool
		return open && peer != null && peer.open;

	public function bufferedBytes():Int
		return queuedBytes;

	public function bufferedMessages():Int
		return incoming.length;

	public function send(message:Bytes):Bool {
		if (message == null)
			throw "Message is required";
		var destination = peer;
		if (!open
			|| destination == null
			|| !destination.open
			|| message.length > destination.maxBytes - destination.queuedBytes
			|| destination.incoming.length >= destination.maxMessages)
			return false;
		if (dropNext) {
			dropNext = false;
			return true;
		}
		destination.incoming.push(message);
		destination.queuedBytes += message.length;
		return true;
	}

	public function receive():Null<Bytes> {
		if (!isOpen() || incoming.length == 0)
			return null;
		var message = incoming.shift();
		queuedBytes -= message.length;
		return message;
	}

	public function close():Void {
		open = false;
		incoming.resize(0);
		queuedBytes = 0;
		if (peer != null) {
			peer.incoming.resize(0);
			peer.queuedBytes = 0;
		}
	}
}
