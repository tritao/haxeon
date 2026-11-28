import haxeon.async.Future;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcError;

// A service's expected failures in a Result: the response type is Result<Answer, E>, with E the service's own error
// enum, and a call answers Result<Result<Answer, E>, RpcError>, the outer one the call's, the inner one the service's.

typedef Query = {
	var name:String;
}

typedef Answer = {
	var text:String;
}

enum Refusal {
	Unknown(name:String);
	Full;
}

interface Directory {
	function find(request:Query):Result<Answer, Refusal>;
	function save(request:Query):Result<Void, Refusal>;
	function later(request:Query):Future<Result<Int, String>>;
}

class DirectoryImpl implements Directory {
	final names:Array<String> = ["Ada"];

	public function new() {}

	public function find(request:Query):Result<Answer, Refusal>
		return names.indexOf(request.name) >= 0 ? Ok({text: "found " + request.name}) : Err(Unknown(request.name));

	public function save(request:Query):Result<Void, Refusal> {
		if (names.length >= 2)
			return Err(Full);
		names.push(request.name);
		return Ok();
	}

	public function later(request:Query):Future<Result<Int, String>> {
		var promise = new haxeon.async.Promise<Result<Int, String>>();
		promise.complete(request.name.length > 0 ? Ok(request.name.length) : Err("empty"));
		return promise.future;
	}
}

function main():Int {
	var pair = MemoryTransport.pair();
	var clock = () -> 0.0;
	var server = new RpcConnection(pair.server, clock);
	var client = new RpcConnection(pair.client, clock);
	server.serve<Directory>(new DirectoryImpl());
	var stub = client.of<Directory>();
	var answers:Array<String> = [];
	function found(outcome:haxeon.async.Outcome<Result<Result<Answer, Refusal>, RpcError>>):Void
		answers.push(switch outcome {
			case Success(Ok(Ok(value))): value.text;
			case Success(Ok(Err(Unknown(name)))): "unknown " + name;
			case Success(Ok(Err(Full))): "full";
			case _: "ended";
		});
	function saved(outcome:haxeon.async.Outcome<Result<Result<Void, Refusal>, RpcError>>):Void
		answers.push(switch outcome {
			case Success(Ok(Ok(_))): "saved";
			case Success(Ok(Err(Unknown(name)))): "unknown " + name;
			case Success(Ok(Err(Full))): "full";
			case _: "ended";
		});
	stub.find({name: "Ada"}).onComplete(found);
	stub.find({name: "Bob"}).onComplete(found);
	stub.save({name: "Bob"}).onComplete(saved);
	stub.save({name: "Cy"}).onComplete(saved);
	stub.later({name: "Grace"}).onComplete(outcome -> answers.push(switch outcome {
		case Success(Ok(Ok(length))): "length " + length;
		case Success(Ok(Err(reason))): reason;
		case _: "ended";
	}));
	for (_ in 0...4) {
		server.poll();
		client.poll();
	}
	var got = answers.join(",");
	return got == "found Ada,unknown Bob,saved,full,length 5" ? 42 : 1;
}
