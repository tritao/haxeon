import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcMethod;
import haxeon.rpc.RpcProtocol;
import haxeon.wire.MessagePack;

interface Pinned {
	@:id(1) function length(request:String):Int;
	@:id(2) function next(request:Int):Int;
}

interface OtherService {
	@:id(1) function next(request:Int):Int;
}

class PinnedImpl implements Pinned {
	public function new() {}

	public function length(request:String):Int
		return request.length;

	public function next(request:Int):Int
		return request + 1;
}

class OtherImpl implements OtherService {
	public function new() {}

	public function next(request:Int):Int
		return request + 2;
}

function main():Int {
	var pair = MemoryTransport.pair();
	var clock = () -> 0.0;
	var client = new RpcConnection(pair.client, clock);
	var server = new RpcConnection(pair.server, clock);
	server.serve(Pinned, new PinnedImpl());
	server.serve(OtherService, new OtherImpl());

	var total = 0;
	var failures = 0;
	var pinned = client.of(Pinned);
	pinned.length("Ada", answer -> total += answer, error -> failures++);
	// Inspect the selector before returning the message to the server's queue.
	var first = pair.server.receive();
	if (first == null)
		return 1;
	switch RpcProtocol.decode(first, 4096) {
		case Request(1, ServiceId("Pinned", 1), _, _):
		default: return 2;
	}
	if (!pair.client.send(first))
		return 3;
	pinned.next(6, answer -> total += answer, error -> failures++);
	client.of(OtherService).next(6, answer -> total += answer, error -> failures++);

	var legacyName = new RpcMethod<String, Int>(0, value -> MessagePack.encode(value),
		bytes -> MessagePack.decode(bytes), value -> MessagePack.encode(value), bytes -> MessagePack.decode(bytes),
		"Pinned.length");
	client.call(legacyName, "Grace", 25, answer -> total += answer, error -> failures++);

	server.poll();
	client.poll();
	return total == 23 && failures == 0 ? 42 : 4;
}
