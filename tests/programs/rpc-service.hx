import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcProtocol;

typedef Query = {
	var name:String;
}

typedef Answer = {
	var text:String;
}

interface Greeter {
	function greet(request:Query):Answer;
	function measure(request:Array<Int>):Int;
}

class GreeterImpl implements Greeter {
	public function new() {}

	public function greet(request:Query):Answer
		return {text: "Hello " + request.name};

	public function measure(request:Array<Int>):Int
		return request.length;
}

function main():Int {
	var pair = MemoryTransport.pair();
	var clock = () -> 0.0;
	var server = new RpcConnection(pair.server, clock);
	var client = new RpcConnection(pair.client, clock);
	server.serve(Greeter, new GreeterImpl());
	var stub = client.of(Greeter);
	var greeting = "";
	var count = 0;
	var failures = 0;
	var first = stub.greet({name: "Ada"}, answer -> greeting = answer.text, error -> failures++);
	var message = pair.server.receive();
	if (message == null)
		return 1;
	switch RpcProtocol.decode(message, 4096) {
		case Request(1, Name("Greeter.greet"), 1000, _):
		default: return 2;
	}
	if (!pair.client.send(message))
		return 3;
	var second = client.of(Greeter, 25).measure([1, 2, 3], answer -> count = answer, error -> failures++);
	server.poll();
	client.poll();
	return first > 0 && second > first && greeting == "Hello Ada" && count == 3 && failures == 0 ? 42 : 4;
}
