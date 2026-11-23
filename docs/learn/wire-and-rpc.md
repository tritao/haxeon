# Wire formats and typed RPC

On main, you can omit `@:wire` and `@:id`. Wire calls infer codecs from types and use member names as keys by
default. To give a field a stable identity across renames, pin a positive numeric `@:id`, as this example does.
Keep that ID when you rename the field and reserve it if you delete the field.

`MessagePack` encodes to bytes. `JsonWire` encodes to text and uses the same numbered schema. Give each decoder an
expected type so the compiler knows which schema to use. In the JSON below, `1` identifies the field and `text`
is its readable name.

`RpcMethod.wire(100)` builds a method descriptor using the request and response types in its annotation. The
method ID identifies the operation and is separate from field IDs. Here the caller and handler share a pair of
in-memory transports. Polling the server handles the request and polling the client delivers the response.

```haxe
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
	final unpacked:Greeting = MessagePack.decode(packed);
	Sys.println(unpacked.text);

	final json = JsonWire.encode(greeting);
	Sys.println(json);
	final restored:Greeting = JsonWire.decode(json);

	final pair = MemoryTransport.pair();
	final clock = () -> 0.0;
	final client = new RpcConnection(pair.client, clock);
	final server = new RpcConnection(pair.server, clock);
	final echo:RpcMethod<Greeting, Greeting> = RpcMethod.wire(100);
	server.register(echo, (request, context) -> {
		context.respond({text: request.text.toUpperCase()});
	});
	client.call(echo, restored, 1000).onComplete(outcome -> switch outcome {
		case Success(answer): Sys.println(answer.text);
		case Failure(error): throw error;
		case Cancelled | Stopped:
	});
	server.poll();
	client.poll();
}
```

```text title="Output"
hello
{"version":1,"value":[["1:text","hello"]]}
HELLO
```

[Example project](examples/wire-and-rpc/)

[MessagePack](../reference/MESSAGEPACK.md), [JsonWire](../reference/JSON_WIRE.md) and [typed RPC](../reference/RPC.md)
