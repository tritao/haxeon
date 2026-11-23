# Typed RPC services

Declare a service as an interface and implement it as a normal Haxe class.
Use `serve` and `of` on established `RpcConnection` instances. When using
`RpcClient` for reconnect, use the connection supplied to its ready hook.

```haxe
typedef Query = { var name:String; }
typedef Answer = { var text:String; }

interface Greeter {
    function greet(request:Query):Answer;
}

class MyGreeter implements Greeter {
    public function new() {}
    public function greet(request:Query):Answer
        return {text: "Hello " + request.name};
}

// server and client are the two established connections.
server.serve(Greeter, new MyGreeter());
var greeter = client.of(Greeter, 1000);
var requestId = greeter.greet({name: "Ada"},
    answer -> Sys.println(answer.text),
    error -> Sys.println(error.code));
```

A service declares its own instance methods on a nonempty, non-generic
interface. Each method takes one required request parameter and returns a
response value. Both types use the compiler's [MessagePack wire profile](MESSAGEPACK.md).
The compiler generates typed dispatch and a stub whose methods take the
request, an answer callback and an error callback. The stub captures its
connection and timeout, which defaults to 1000 milliseconds. Calls return
the request ID, which can be passed to `connection.cancel(requestId)`.
Poll both connections to dispatch requests and deliver replies. Service
implementations return their response synchronously and should avoid blocking
the poll loop. The interface API currently supports request/response methods.
Streaming and subscriptions can add new method forms in the future.

The default wire identity is the qualified interface name followed by the
method name, such as `Greeter.greet` or `example.Greeter.greet`. RPC protocol
version 2 encodes each request's method selector as a tagged MessagePack
value. The three forms are a low-level integer ID, a qualified method name,
and an integer ID scoped to a qualified service name. A request is the
MessagePack map `{4: [requestId, selector, timeoutMs, payload]}`. The
selectors are `{1: [id]}`, `{2: [qualifiedMethodName]}`, and
`{3: [qualifiedServiceName, id]}`, respectively. Carrying names directly
avoids hash collisions. The handshake rejects peers with a
different protocol version. The MessagePack codec version stays at 1.

## Pin service method IDs

Run `haxeon lint --fix --pin-wire Greeter src/Greeter.hx` to write
consecutive `@:id(n)` annotations starting at 1, in declaration order.
Rerunning the command preserves IDs. Every method of an interface must use
the same identity mode, and pinned IDs must be positive and unique within
that interface. A pinned stub sends a scoped ID, and a pinned server
accepts both IDs and current qualified names. Upgrade servers before
switching clients to IDs. Preserve IDs when reordering or renaming methods,
keep retired IDs reserved, and give new methods fresh IDs. The qualified
interface name remains part of the identity in both modes.

## Handshake and reconnect

Create immutable `RpcPeerOptions` with an application version string, offered
capabilities, required capabilities and resource limits. Protocol and codec
versions are checked independently; application compatibility is a service policy.
The server intersects capabilities and can apply an authorization callback before
sending Welcome. Transport authentication must already have succeeded at the
adapter boundary. No privileged connection is exposed before negotiation succeeds.

```haxe
var options = new RpcPeerOptions("workspace/1", ["files.read", "events"], ["files.read"]);
var client = new RpcClient(connector, monotonicMilliseconds, randomUnit, options,
    function(connection, generation, capabilities) {
        // Explicitly attach resources or resume subscriptions using saved cursors.
        // Fence deferred application callbacks with client.isCurrent(generation).
    });
```

A `RpcConnector` completes with an owned transport or a structured failure and
returns a cancellable attempt. Completion may be synchronous. Cancellation after
completion must not close a transferred transport. Late completions are fenced;
a stale newly opened transport is closed. Each new attempt has a fresh generation,
handshake and connection. Disconnect fails accepted calls with ambiguity; no calls
or resource-creating subscriptions are automatically replayed.

Poll from the host event loop, including on transport readiness. `nextWakeAt()`
returns the next absolute clock deadline for connection timeout, handshake,
backoff or pending RPC work; the host owns timers and cancellation. Polling is
nonblocking and non-reentrant. Retry delay doubles to a configured cap with
injected jitter in the upper half of each delay. A stable connected lifetime
resets backoff. Explicit close cancels attempts and disables retry. Authentication,
protocol/codec, capability and malformed-protocol failures are terminal.

Reconnect capabilities can only shrink within a client lifetime. Regaining
permissions requires an explicit new client/policy decision. Capability negotiation
does not itself enforce method permissions: services must gate their handlers.
The ready hook is the explicit restoration point; cursor storage, replay-gap
handling, snapshots and mutation reconciliation remain application responsibilities.

A rejected server handshake sends Refused and waits for peer close or its original
bounded deadline before abrupt transport cleanup, preserving delivery of the
accepted refusal. Handshake polling processes at most one send and one receive.

## Low-level methods and asynchronous responses

For a hand-built protocol, give each low-level method a permanent positive
integer ID. For wire types,
`RpcMethod.wire(id)` uses the expected `RpcMethod<Request, Response>` type to
generate MessagePack codecs for both types. The descriptor preserves both types
through `call` and `register` without reflection or `Dynamic` in the codecs.

```haxe
typedef Query = { var name:String; }
typedef Answer = { var text:String; }

var method:RpcMethod<Query, Answer> = RpcMethod.wire(100);

server.register(method, function(request, context) {
    // Retaining context for later asynchronous completion is supported.
    context.respond({text: request.name});
});
client.call(method, {name: "workspace"}, 1000,
    function(answer) { Sys.println(answer.text); },
    function(error) { Sys.println(error.code); });
```

Request and response schemas are inferred recursively. Fields and enum constructors
use names by default.

For custom codecs, pass the functions explicitly to
`new RpcMethod<Query, Answer>(100, encodeQuery, decodeQuery, encodeAnswer, decodeAnswer)`.

Poll each endpoint from its event loop. Inject a monotonic clock returning
milliseconds; `RpcContext.deadline()` uses the same clock domain. Polling is
nonblocking and not reentrant. Handlers must also avoid blocking the loop.

A context completes at most once. `respond`/`fail` return false after completion,
cancellation, expiry or disconnect, including when a retained context outlives
its connection. Check `isCancelled()` during asynchronous work. Request ids
increase within a connection and cannot be reused; a duplicate incoming id closes
that connection instead of executing the request again.

## Data that must last: pin IDs

For schemas that must survive member renames, run
`haxeon lint --fix --pin-wire TYPE FILE` for each request, response, or nested
declaration that needs permanent member identities. This changes the payload
encoding. Upgrade readers before sending numbered payloads. Pinned readers can
still read existing name-keyed payloads, as described in the
[MessagePack reference](MESSAGEPACK.md#data-that-must-last-pin-ids).
Method IDs are independent of request and response member IDs.

## Failure semantics

A positive `call` id means transport accepted the request. A returned zero means
it was definitely not dispatched (disconnected, busy or expired during encoding).
Invalid local arguments or failing local encoders throw before dispatch.

Timeout and cancellation end the caller's wait. They do not guarantee server
rollback; `RpcError.ambiguous` records whether execution may have occurred.
Disconnect fails accepted calls with ambiguity, and late replies are ignored.
The runtime never replays requests. Mutations need application-owned operation
ids and reconciliation when their replies are lost.

Unknown methods, overload and malformed request payloads fail without invoking
the handler. A handler exception becomes a generic `handler_failed` error without
serializing its private exception. Malformed envelopes or notifications close
the connection; `closeReason` identifies the local cause. Application callback
exceptions remain visible to the polling caller. Closing retires all pending
waiters even when a failure callback throws.

Notifications have a positive permanent id and a concrete payload codec. They
are best effort; unknown notification ids are ignored. Sequencing, replay cursors,
gap detection and durable subscriptions belong to the application.

## Bounds and ownership

Connection limits bound message size, pending client calls, active asynchronous
server contexts, queued messages and queued bytes. A poll bounds both incoming
and outgoing message counts and bytes, including traffic generated by handlers.
Deadline scans are bounded by the configured call limit. If an incoming message
would exceed the remaining byte budget, one bounded message is retained for the
next poll. Output queue overflow closes the connection, preserving uncertainty
rather than dropping responses silently. The transport must independently bound
its receive queues and native/socket buffers.

`MessageTransport.send` transfers immutable buffer ownership on success; rejection
leaves ownership with the caller. `receive` transfers it to its caller.
`MemoryTransport` retains buffers without copying and can simulate accepted loss.
For streams, `MessagePackFrameReader.feed` returns consumed bytes; retain and retry
the unconsumed input after draining `take()`. The reader validates length before
allocating a payload, and `take` transfers the assembled buffer without another
framing copy. WebSocket adapters already provide message boundaries.

Serialization and networking are not zero copy. The current typed envelope codec
copies nested payload bytes, generated decoding can allocate typed values, and
framing assembly copies incoming chunks into its owned payload.
