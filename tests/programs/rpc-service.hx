import haxeon.async.Future;
import haxeon.async.Promise;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import haxeon.rpc.RpcError;
import haxeon.rpc.RpcProtocol;

typedef Query = {
	var name:String;
}

typedef Answer = {
	var text:String;
}

typedef Deferred<T> = Future<T>;

// An error the service expects to give is in its response type; RpcError is the call's.
enum Checked {
	Accepted(answer:Answer);
	TooLong(limit:Int);
}

interface Greeter {
	function greet(request:Query):Answer;
	function measure(request:Array<Int>):Int;
	function later(request:Query):Deferred<Answer>;
	function check(request:Query):Checked;
}

class GreeterImpl implements Greeter {
	public var pending:Promise<Answer>;
	public var cancellations:Int = 0;

	public function new() {}

	public function greet(request:Query):Answer {
		if (request.name == "")
			throw new haxe.Exception("a greeting needs a name");
		return {text: "Hello " + request.name};
	}

	public function measure(request:Array<Int>):Int
		return request.length;

	public function check(request:Query):Checked
		return request.name.length > 3 ? TooLong(3) : Accepted({text: request.name});

	public function later(request:Query):Future<Answer> {
		var promise = new Promise<Answer>();
		promise.setControls(() -> {
			cancellations++;
			promise.cancel();
		});
		pending = promise;
		return promise.future;
	}
}

function main():Int {
	var pair = MemoryTransport.pair();
	var clock = () -> 0.0;
	var server = new RpcConnection(pair.server, clock);
	var client = new RpcConnection(pair.client, clock);
	var implementation = new GreeterImpl();
	server.serve(Greeter, implementation);
	var stub = client.of(Greeter);
	var greeting = "";
	var count = 0;
	var failures = 0;
	var first:Future<Result<Answer, RpcError>> = stub.greet({name: "Ada"});
	first.onComplete(outcome -> switch outcome {
		case Success(Ok(answer)): greeting = answer.text;
		case _: failures++;
	});
	var message = pair.server.receive();
	if (message == null)
		return 1;
	switch RpcProtocol.decode(message, 4096) {
		case Ok(Request(1, Name("Greeter.greet"), 1000, _)):
		default: return 2;
	}
	if (!pair.client.send(message))
		return 3;
	client.of(Greeter, 25).measure([1, 2, 3]).onComplete(outcome -> switch outcome {
		case Success(Ok(answer)): count = answer;
		case _: failures++;
	});
	server.poll();
	client.poll();
	if (greeting != "Hello Ada" || count != 3 || failures != 0)
		return 4;

	var later:Future<Result<Answer, RpcError>> = stub.later({name: "Grace"});
	later.onComplete(outcome -> switch outcome {
		case Success(Ok(answer)): greeting = answer.text;
		case _: failures++;
	});
	server.poll();
	client.poll();
	if (later.isComplete() || server.activeRequests() != 1)
		return 5;
	implementation.pending.complete({text: "Hello Grace"});
	client.poll();
	if (greeting != "Hello Grace" || failures != 0)
		return 6;

	var cancelled = stub.later({name: "Ada"});
	var didCancel = false;
	cancelled.onComplete(outcome -> didCancel = outcome.match(Cancelled));
	server.poll();
	if (!cancelled.cancel() || !didCancel)
		return 7;
	server.poll();
	if (implementation.cancellations != 1 || server.activeRequests() != 0)
		return 8;

	var stopped = stub.later({name: "Ada"});
	var didStop = false;
	stopped.onComplete(outcome -> didStop = outcome.match(Stopped));
	server.poll();
	if (!stopped.stopObserving() || !didStop || client.pendingCalls() != 0)
		return 9;
	server.poll();
	if (implementation.cancellations != 1 || server.activeRequests() != 1)
		return 10;
	implementation.pending.complete({text: "unobserved"});
	client.poll();

	// A handler that throws has a bug on the peer: the call fails with HandlerFailed, which may have run.
	var remoteError:Null<RpcError> = null;
	stub.greet({name: ""}).onComplete(outcome -> switch outcome {
		case Success(Err(error)): remoteError = error;
		case _:
	});
	server.poll();
	client.poll();
	if (remoteError == null || !remoteError.match(HandlerFailed) || !remoteError.mayHaveRun())
		return 11;

	var refused:Null<Checked> = null;
	stub.check({name: "Grace"}).onComplete(outcome -> switch outcome {
		case Success(Ok(reply)): refused = reply;
		case _:
	});
	server.poll();
	client.poll();
	if (refused == null || !refused.match(TooLong(3)))
		return 12;

	remoteError = null;
	stub.later({name: "Ada"}).onComplete(outcome -> switch outcome {
		case Success(Err(error)): remoteError = error;
		case _:
	});
	server.poll();
	server.close();
	client.poll();
	return remoteError != null && remoteError.match(Disconnected(true)) && implementation.cancellations == 2 ? 42 : 13;
}
