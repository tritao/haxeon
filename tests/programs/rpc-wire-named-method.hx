import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcMethod;

typedef Query = {
	var name:String;
}

typedef Answer = {
	var text:String;
	var length:Int;
}

function main():Int {
	var pair = MemoryTransport.pair();
	var clock = () -> 0.0;
	var client = new RpcConnection(pair.client, clock);
	var server = new RpcConnection(pair.server, clock);
	var method:RpcMethod<Query, Answer> = RpcMethod.wire(100);
	server.register(method, (request, context) -> {
		context.respond({text: "Hello " + request.name, length: request.name.length});
	});
	var result = 1;
	var future = client.call(method, {name: "workspace"}, 25);
	future.onComplete(outcome -> switch outcome {
		case Success(Ok(answer)): result = answer.text == "Hello workspace" && answer.length == 9 ? 42 : 2;
		case _: result = 3;
	});
	if (!future.canCancel())
		return 4;
	server.poll();
	client.poll();
	return result;
}
