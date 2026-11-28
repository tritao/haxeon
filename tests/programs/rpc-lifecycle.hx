import haxeon.rpc.*;
import haxe.io.Bytes;

class Attempt implements RpcConnectAttempt {
	public function new() {}

	public function cancel():Void {}
}

class Connector implements RpcConnector {
	public var transport:MessageTransport;

	public function new(transport:MessageTransport) {
		this.transport = transport;
	}

	public function connect(complete:Result<MessageTransport, RpcError>->Void):RpcConnectAttempt {
		complete(Ok(transport));
		return new Attempt();
	}
}

function main():Int {
	var now = 0.0;
	var clock = () -> now;
	var pair = MemoryTransport.pair(4096, 16);
	var connector = new Connector(pair.client);
	var options = new RpcPeerOptions("fixture/1", ["read", "events"], ["read"], 50, 1024, 4, 4096);
	var ready = 0;
	var client = new RpcClient(connector, clock, () -> 1.0, options, (_, _, _) -> {
		ready++;
	}, 10, 40, 30);
	var server = RpcHandshake.server(pair.server, clock, options);
	for (index in 0...8) {
		client.poll();
		server.poll();
	}
	if (ready != 1 || !client.isCurrent(1) || client.capabilities().length != 2)
		return 1;
	var vector = RpcProtocol.encode(Hello(RpcProtocol.VERSION, RpcProtocol.CODEC_VERSION, "fixture/1", ["read"]), 1024);
	var hex = "";
	for (index in 0...vector.length)
		hex += StringTools.hex(vector.get(index), 2);
	if (hex != "8101940201A9666978747572652F3191A472656164")
		return 2;
	var method = new RpcMethod<String, String>(100, text -> Bytes.ofString(text),
		(bytes:Bytes) -> Ok(bytes.toString()),
		text -> Bytes.ofString(text),
		(bytes:Bytes) -> Ok(bytes.toString()));
	var service = server.connection;
	var active = client.current();
	if (service == null || active == null)
		return 3;
	service.register(method, (value, context) -> {
		context.respond(value + "!");
	});
	var answer = "";
	active.call(method, "hello", 25).onComplete(outcome -> switch outcome {
		case Success(Ok(value)): answer = value;
		case _:
	});
	service.poll();
	client.poll();
	if (answer != "hello!")
		return 4;
	pair.server.close();
	client.poll();
	var dropped = client.lastError;
	if (client.isCurrent(1) || client.nextWakeAt() != 10 || dropped == null || !dropped.match(Disconnected(false)))
		return 5;
	now = 10;
	pair = MemoryTransport.pair(4096, 16);
	connector.transport = pair.client;
	server = RpcHandshake.server(pair.server, clock, new RpcPeerOptions("fixture/2", ["read"], [], 50, 1024, 4, 4096));
	for (index in 0...8) {
		client.poll();
		server.poll();
	}
	if (ready != 2 || !client.isCurrent(2) || client.capabilities().length != 1)
		return 6;
	client.close();
	if (client.nextWakeAt() != null || client.current() != null)
		return 7;

	pair = MemoryTransport.pair(4096, 16);
	server = RpcHandshake.server(pair.server, clock, options);
	if (!pair.client.send(RpcProtocol.encode(Hello(1, RpcProtocol.CODEC_VERSION, "fixture/1", ["read"]), 1024)))
		return 8;
	server.poll();
	server.poll();
	var refusal = pair.client.receive();
	if (refusal == null || server.connection != null)
		return 9;
	switch RpcProtocol.decode(refusal, 1024) {
		case Ok(Refused(error)) if (error.code == "unsupported_protocol"):
		default: return 10;
	}
	// A refusal the server's policy gives reaches the client as the error it chose, and ends the client.
	pair = MemoryTransport.pair(4096, 16);
	connector.transport = pair.client;
	var refusing = new RpcClient(connector, clock, () -> 1.0, options, (_, _, _) -> {}, 10, 40, 30);
	server = RpcHandshake.server(pair.server, clock, options,
		(application, capabilities) -> Err(AuthorizationFailed("fixture is not allowed")));
	for (index in 0...8) {
		refusing.poll();
		server.poll();
	}
	var refused = refusing.lastError;
	if (refusing.state != Closed || refused == null || !refused.match(AuthorizationFailed("fixture is not allowed")))
		return 11;
	return 42;
}
