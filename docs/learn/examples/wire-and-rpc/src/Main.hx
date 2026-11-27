import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcMethod;
import haxeon.wire.JsonWire;
import haxeon.wire.MessagePack;

@:wire typedef Greeting = {
	@:id(1) var text:String;
}

function main():Void {
	final greeting:Greeting = {text: "hello"};
	final packed = MessagePack.encode(greeting);
	switch MessagePack.decode<Greeting>(packed) {
		case Ok(value): Sys.println(value.text);
		case Err(error): Sys.println('Not a greeting: $error');
	}

	final json = JsonWire.encode(greeting);
	Sys.println(json);
	final restored = JsonWire.decode<Greeting>(json);

	final pair = MemoryTransport.pair();
	final clock = () -> 0.0;
	final client = new RpcConnection(pair.client, clock);
	final server = new RpcConnection(pair.server, clock);
	final echo = RpcMethod.wire<Greeting, Greeting>(100);
	server.register(echo, (request, context) -> {
		context.respond({text: request.text.toUpperCase()});
	});
	client.call(echo, restored.unwrap(), 1000).onComplete(outcome -> switch outcome {
		case Success(Ok(answer)): Sys.println(answer.text);
		case Success(Err(error)): Sys.println('Call failed: ${error.code()}');
		case Failure(_) | Cancelled | Stopped:
	});
	server.poll();
	client.poll();
}
