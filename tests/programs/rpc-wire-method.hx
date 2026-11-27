import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcMethod;

@:wire typedef Query = {
	@:id(1) var name:String;
}

@:wire typedef Answer = {
	@:id(1) var text:String;
	@:id(2) var length:Int;
}

function main():Int {
	var pair = MemoryTransport.pair();
	var clock = function() return 0.0;
	var client = new RpcConnection(pair.client, clock);
	var server = new RpcConnection(pair.server, clock);
	var method = RpcMethod.wire<Query, Answer>(100);
	server.register(method, function(request, context) {
		context.respond({text: "Hello " + request.name, length: request.name.length});
	});
	var result = 1;
	var future = client.call(method, {name: "workspace"}, 25);
	future.onComplete(outcome -> switch outcome {
		case Success(answer): result = answer.text == "Hello workspace" && answer.length == 9 ? 42 : 2;
		case _: result = 3;
	});
	if (!future.canCancel())
		return 4;
	server.poll();
	client.poll();
	return result;
}
