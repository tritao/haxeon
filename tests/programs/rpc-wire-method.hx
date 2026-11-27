import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcError;
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
		case Success(Ok(answer)): result = answer.text == "Hello workspace" && answer.length == 9 ? 42 : 2;
		case _: result = 3;
	});
	if (!future.canCancel())
		return 4;
	server.poll();
	client.poll();
	if (result != 42)
		return result;
	// A handler's own error reaches the caller as it sent it.
	var refusing = RpcMethod.wire<Query, Answer>(101), refusal:Null<RpcError> = null;
	server.register(refusing, function(request, context) {
		context.fail(Remote("rejected", "Greeting rejected", true));
	});
	client.call(refusing, {name: "Ada"}, 25).onComplete(outcome -> switch outcome {
		case Success(Err(error)): refusal = error;
		case _:
	});
	server.poll();
	client.poll();
	if (refusal == null || !refusal.match(Remote("rejected", "Greeting rejected", true)) || !refusal.mayHaveRun())
		return 5;
	// A method the peer does not handle, and a call on a closed connection, fail with errors of their own.
	var unknown = RpcMethod.wire<Query, Answer>(102), failures:Array<RpcError> = [];
	client.call(unknown, {name: "Ada"}, 25).onComplete(outcome -> switch outcome {
		case Success(Err(error)): failures.push(error);
		case _:
	});
	server.poll();
	client.poll();
	client.close();
	client.call(method, {name: "Ada"}, 25).onComplete(outcome -> switch outcome {
		case Success(Err(error)): failures.push(error);
		case _:
	});
	return failures.length == 2 && failures[0].match(UnknownMethod) && failures[1].match(Disconnected(false)) ? 42 : 6;
}
