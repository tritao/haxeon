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

	public function connect(complete:RpcConnectResult->Void):RpcConnectAttempt {
		complete(Opened(transport));
		return new Attempt();
	}
}

function main():Int {
	var now = 0.0;
	var clock = function() return now;
	var pair = MemoryTransport.pair(4096, 16);
	var connector = new Connector(pair.client);
	var options = new RpcPeerOptions("fixture/1", ["read", "events"], ["read"], 50, 1024, 4, 4096);
	var ready = 0;
	var client = new RpcClient(connector, clock, function() return 1.0, options, function(_, _, _) {
		ready++;
	}, 10, 40, 30);
	var server = RpcHandshake.server(pair.server, clock, options);
	for (index in 0...8) {
		client.poll();
		server.poll();
	}
	if (ready != 1 || !client.isCurrent(1) || client.capabilities().length != 2)
		return 1;
	var vector = RpcProtocol.encode(Hello(1, 1, "fixture/1", ["read"]), 1024);
	var hex = "";
	for (index in 0...vector.length)
		hex += StringTools.hex(vector.get(index), 2);
	if (hex != "8101940101A9666978747572652F3191A472656164")
		return 2;
	var method = new RpcMethod<String, String>(100, Bytes.ofString, function(bytes:Bytes) return bytes.toString(), Bytes.ofString,
		function(bytes:Bytes) return bytes.toString());
	var service = server.connection;
	var active = client.current();
	if (service == null || active == null)
		return 3;
	service.register(method, function(value, context) {
		context.respond(value + "!");
	});
	var answer = "";
	active.call(method, "hello", 25, function(value) {
		answer = value;
	}, function(_) {});
	service.poll();
	client.poll();
	if (answer != "hello!")
		return 4;
	pair.server.close();
	client.poll();
	if (client.isCurrent(1) || client.nextWakeAt() != 10)
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
	return 42;
}
