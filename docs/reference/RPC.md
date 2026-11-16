# Typed RPC runtime

`haxeon.rpc` supplies transport-independent RPC over the existing typed wire
codecs. `RpcConnection` owns one established generation; `RpcHandshake`
negotiates it and `RpcClient` manages cancellable connection attempts and reconnect.

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

## Methods and asynchronous responses

Give each method a permanent positive integer id and concrete request/response
codecs. Construct codecs at concrete types so compiler-owned MessagePack calls
can generate them. A descriptor preserves both types through `call` and
`register`; dispatch stores byte-oriented closures without Dynamic/reflection.

```haxe
@:wire typedef Query = { @:id(1) var name:String; }
@:wire typedef Answer = { @:id(1) var text:String; }

var method = new RpcMethod<Query, Answer>(100,
    function(value:Query) return MessagePack.encode(value),
    function(bytes:Bytes):Query return MessagePack.decode(bytes),
    function(value:Answer) return MessagePack.encode(value),
    function(bytes:Bytes):Answer return MessagePack.decode(bytes));

server.register(method, function(request, context) {
    // Retaining context for later asynchronous completion is supported.
    context.respond({text: request.name});
});
client.call(method, {name: "workspace"}, 1000,
    function(answer) { Sys.println(answer.text); },
    function(error) { Sys.println(error.code); });
```

Poll each endpoint from its event loop. Inject a monotonic clock returning
milliseconds; `RpcContext.deadline()` uses the same clock domain. Polling is
nonblocking and not reentrant. Handlers must also avoid blocking the loop.

A context completes at most once. `respond`/`fail` return false after completion,
cancellation, expiry or disconnect, including when a retained context outlives
its connection. Check `isCancelled()` during asynchronous work. Request ids
increase within a connection and cannot be reused; a duplicate incoming id closes
that connection instead of executing the request again.

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
