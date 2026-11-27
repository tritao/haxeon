package haxeon.rpc;

import haxe.io.Bytes;
import haxeon.async.Future;
import haxeon.async.Promise;
import haxeon.rpc.RpcMethod.RpcRoute;
import haxeon.wire.WireError;

private typedef PendingCall = {
	var deadline:Float;
	var response:Bytes->Void;
	var failure:RpcError->Void;
}

/**
 * One established connection to a peer, over a transport: calls and notifications both ways. The handshake and
 * reconnecting belong to its owner, an `RpcClient` or a server. `poll` does its work without blocking, within a budget.
 * A request is sent once and never replayed. Clock values and deadlines are monotonic milliseconds.
 */
class RpcConnection {
	/**
	 * Why the connection closed, once it has: `Disconnected(false)` when this side or the transport closed it, or the
	 * `ProtocolViolation` of a peer that broke the protocol.
	 */
	public var closeError(default, null):Null<RpcError>;

	final transport:MessageTransport;
	final clock:Void->Float;
	final maxMessageBytes:Int;
	final maxCalls:Int;
	final maxQueuedBytes:Int;
	final handlers:Map<String, (Bytes, RpcRequestState) -> Void> = [];
	final notifications:Map<Int, Bytes -> Void> = [];
	var pending:Map<Int, PendingCall> = [];
	var active:Map<Int, RpcRequestState> = [];
	final outgoing:Array<Bytes> = [];
	var queuedBytes:Int = 0;
	var pendingCount:Int = 0;
	var activeCount:Int = 0;
	var nextId:Int = 1;
	var lastRequestId:Int = 0;
	var open:Bool = true;
	var held:Null<Bytes>;
	var polling:Bool = false;
	var sendMessagesLeft:Int = 0;
	var sendBytesLeft:Int = 0;

	/**
	 * A connection over `transport`, with `clock` giving monotonic milliseconds. It refuses a message over
	 * `maxMessageBytes`, more than `maxCalls` calls in flight, and more than `maxQueuedBytes` bytes waiting to be sent.
	 */
	public function new(transport:MessageTransport, clock:Void->Float, maxMessageBytes:Int = 4 * 1024 * 1024,
			maxCalls:Int = 256,
			maxQueuedBytes:Int = 8 * 1024 * 1024) {
		if (maxMessageBytes < 128
			|| maxCalls < 1
			|| maxQueuedBytes < maxMessageBytes
			|| maxQueuedBytes > 0x7fffffff - maxMessageBytes)
			throw new haxe.Exception("Invalid RPC connection limits");
		this.transport = transport;
		this.clock = clock;
		this.maxMessageBytes = maxMessageBytes;
		this.maxCalls = maxCalls;
		this.maxQueuedBytes = maxQueuedBytes;
	}

	/** Whether the connection and its transport are open. */
	public function isOpen():Bool
		return open && transport.isOpen();

	/** How many calls this side made that have no response yet. */
	public function pendingCalls():Int
		return pendingCount;

	/** How many of the peer's requests this side is handling. */
	public function activeRequests():Int
		return activeCount;

	/** Earliest active deadline, for the host's event-loop scheduler. */
	public function nextDeadline():Null<Float> {
		var earliest:Null<Float> = null;
		for (call in pending)
			if (earliest == null || call.deadline < earliest)
				earliest = call.deadline;
		for (request in active)
			if (earliest == null || request.deadline < earliest)
				earliest = request.deadline;
		return earliest;
	}

	/** How many bytes wait to be sent. */
	public function bufferedBytes():Int
		return queuedBytes + (held == null ? 0 : held.length);

	/**
	 * Handles the peer's calls of `method` with `handler`, which answers through its context. Throws when the method is
	 * already handled.
	 */
	public function register<Request, Response>(method:RpcMethod<Request, Response>,
			handler:(Request, RpcContext<Response>) -> Void):Void {
		installRoutes([@:privateAccess method.route(handler, finish)]);
	}

	/** Check every selector before publishing any route in a service. */
	function installRoutes(routes:Array<RpcRoute>):Void {
		var incoming:Map<String, (Bytes, RpcRequestState) -> Void> = [];
		for (route in routes)
			for (selector in route.selectors) {
				var key = methodKey(selector);
				if (handlers.exists(key) || incoming.exists(key))
					throw new haxe.Exception("Duplicate RPC method");
				incoming.set(key, route.handle);
			}
		for (key => handler in incoming)
			handlers.set(key, handler);
	}

	static function methodKey(method:RpcMethodKey):String
		return switch method {
			case Id(id): 'id:$id';
			case Name(name): 'name:$name';
			case ServiceId(service, id): 'service:$service:$id';
		};

	/**
	 * Handles the peer's notifications `id` with `handler`, decoding each with `decode`; one that does not decode
	 * closes the connection. Throws when `id` is not positive or is already handled.
	 */
	public function onNotification<T>(id:Int, decode:Bytes->Result<T, WireError>, handler:T->Void):Void {
		if (id <= 0 || notifications.exists(id))
			throw new haxe.Exception("Invalid or duplicate notification id");
		notifications.set(id, function(bytes) switch decode(bytes) {
			case Ok(value): handler(value);
			case Err(_): closeWith(ProtocolViolation("invalid_notification"));
		});
	}

	/**
	 * Sends the notification `id` with `value`, which expects no response: false when the connection is closed or its
	 * queue is full.
	 */
	public function notify<T>(id:Int, value:T, encode:T->Bytes):Bool {
		if (!isOpen())
			return false;
		return enqueue(Notification(id, encode(value)));
	}

	/**
	 * Sends one request: its future settles with the response, or with the error that ended the call. Cancelling the
	 * future asks the peer to stop the request. Throws when `timeoutMs` is not positive.
	 */
	public function call<Request, Response>(method:RpcMethod<Request, Response>, request:Request,
			timeoutMs:Int):Future<Result<Response, RpcError>> {
		var promise = new Promise<Result<Response, RpcError>>();
		function fail(error:RpcError):Future<Result<Response, RpcError>> {
			promise.complete(Err(error));
			return promise.future;
		}
		if (!isOpen())
			return fail(Disconnected(false));
		if (timeoutMs <= 0)
			throw new haxe.Exception("RPC timeout must be positive");
		if (pendingCount >= maxCalls || nextId == 0x7fffffff || outgoing.length > 0)
			return fail(Busy);
		var id = nextId++;
		var deadline = clock() + timeoutMs;
		var bytes = RpcProtocol.encode(Request(id, method.key, timeoutMs, method.encodeRequest(request)),
			maxMessageBytes);
		if (clock() >= deadline)
			return fail(TimedOut(false));
		if (!trySend(bytes))
			return fail(isOpen() ? Busy : Disconnected(false));
		pending.set(id, {deadline: deadline,
			response: bytes -> promise.complete(switch method.decodeResponse(bytes) {
				case Ok(value): Ok(value);
				case Err(_): Err(InvalidResponse);
			}),
				failure: error -> promise.complete(Err(error))});
		pendingCount++;
		promise.setControls(function() {
			takePending(id);
			sendCancellation(id, promise.cancel);
		}, function() takePending(id));
		return promise.future;
	}

	function sendCancellation(id:Int, settle:Void->Void):Void {
		try
			enqueue(Cancel(id))
		catch (failure:Dynamic) {
			settle();
			throw failure;
		}
		settle();
	}

	function takePending(id:Int):Null<PendingCall> {
		var call = pending.get(id);
		if (call != null) {
			pending.remove(id);
			pendingCount--;
		}
		return call;
	}

	function finish(state:RpcRequestState, bytes:Bytes, failure:Null<RpcError>):Bool {
		if (!open || !state.isActive() || active.get(state.id) != state)
			return false;
		var encoded = RpcProtocol.encode(failure == null ? Response(state.id, bytes) : Failed(state.id,
			RpcProtocol.errorToWire(failure)),
			maxMessageBytes);
		active.remove(state.id);
		activeCount--;
		state.finish(false);
		return enqueueBytes(encoded);
	}

	function enqueue(message:RpcEnvelope):Bool {
		if (!isOpen())
			return false;
		var bytes = RpcProtocol.encode(message, maxMessageBytes);
		return enqueueBytes(bytes);
	}

	function enqueueBytes(bytes:Bytes):Bool {
		if (!isOpen())
			return false;
		if (outgoing.length == 0 && trySend(bytes))
			return true;
		if (outgoing.length >= maxCalls || bytes.length > maxQueuedBytes - queuedBytes) {
			closeWith(Busy);
			return false;
		}
		outgoing.push(bytes);
		queuedBytes += bytes.length;
		return true;
	}

	function trySend(bytes:Bytes):Bool {
		if (polling && (sendMessagesLeft == 0 || bytes.length > sendBytesLeft))
			return false;
		if (!transport.send(bytes))
			return false;
		if (polling) {
			sendMessagesLeft--;
			sendBytesLeft -= bytes.length;
		}
		return true;
	}

	/** Closes the connection and its transport: pending calls fail and the peer's requests are cancelled. */
	public function close():Void
		closeWith(Disconnected(false));

	/** `close`, recording `error` as why. */
	function closeWith(error:RpcError):Void {
		if (!open)
			return;
		open = false;
		closeError = error;
		transport.close();
		held = null;
		outgoing.resize(0);
		queuedBytes = 0;
		var calls = pending;
		pending = [];
		pendingCount = 0;
		var requests = active;
		active = [];
		activeCount = 0;
		// One failing application callback must not strand the remaining waiters.
		var callbackError:Dynamic = null;
		var callbackFailed = false;
		for (state in requests)
			try
				state.finish(true)
			catch (failure:Dynamic) {
				if (!callbackFailed)
					callbackError = failure;
				callbackFailed = true;
			}
		for (call in calls)
			try
				call.failure(Disconnected(true))
			catch (failure:Dynamic) {
				if (!callbackFailed)
					callbackError = failure;
				callbackFailed = true;
			}
		if (callbackFailed)
			throw callbackError;
	}

	/** Bounds messages/encoded bytes in each direction, including handler replies.
	 * Deadline scanning is additionally bounded by maxCalls in each direction. */
	public function poll(messageBudget:Int = 32, ?byteBudget:Int):Int {
		var bytes = byteBudget == null ? maxMessageBytes : byteBudget;
		if (polling)
			throw new haxe.Exception("RPC poll is not reentrant");
		if (messageBudget < 1 || bytes < maxMessageBytes)
			throw new haxe.Exception("Invalid RPC poll budget");
		polling = true;
		#if !haxe_ver
		defer polling = false;
		#end
		sendMessagesLeft = messageBudget;
		sendBytesLeft = bytes;
		#if !haxe_ver
		return pollInternal(messageBudget, bytes);
		#else
		var count:Int;
		try
			count = pollInternal(messageBudget, bytes)
		catch (failure:Dynamic) {
			polling = false;
			throw failure;
		}
		polling = false;
		return count;
		#end
	}

	function pollInternal(messageBudget:Int, byteBudget:Int):Int {
		if (!isOpen()) {
			close();
			return 0;
		}
		while (outgoing.length > 0) {
			var bytes = outgoing[0];
			if (!trySend(bytes))
				break;
			outgoing.shift();
			queuedBytes -= bytes.length;
		}
		var now = clock();
		var expired:Array<Int> = [];
		for (id => call in pending)
			if (now >= call.deadline)
				expired.push(id);
		for (id in expired) {
			var call = takePending(id);
			if (call != null)
				sendCancellation(id, () -> call.failure(TimedOut(true)));
		}
		var expiredRequests:Array<Int> = [];
		for (id => state in active)
			if (now >= state.deadline)
				expiredRequests.push(id);
		for (id in expiredRequests) {
			var state = active.get(id);
			if (state != null) {
				active.remove(id);
				activeCount--;
				state.finish(true);
				enqueue(Failed(id, RpcProtocol.errorToWire(TimedOut(true))));
			}
		}
		var count = 0, used = 0;
		while (open && count < messageBudget) {
			var bytes = held;
			if (bytes == null)
				bytes = transport.receive();
			if (bytes == null)
				break;
			if (bytes.length > maxMessageBytes) {
				closeWith(ProtocolViolation("oversized_message"));
				break;
			}
			if (bytes.length > byteBudget - used) {
				held = bytes;
				break;
			}
			held = null;
			used += bytes.length;
			count++;
			switch RpcProtocol.decode(bytes, maxMessageBytes) {
				case Ok(message): dispatch(message);
				case Err(_):
					closeWith(ProtocolViolation("invalid_envelope"));
					break;
			}
		}
		return count;
	}

	function dispatch(message:RpcEnvelope):Void {
		switch message {
			case Response(id, bytes):
				var call = takePending(id);
				if (call != null) {
					if (clock() >= call.deadline)
						call.failure(TimedOut(true));
					else
						call.response(bytes);
				}
			case Failed(id, failure):
				var call = takePending(id);
				if (call != null)
					call.failure(clock() >= call.deadline ? TimedOut(true) : RpcProtocol.errorFromWire(failure));
			case Cancel(id):
				var state = active.get(id);
				if (state != null) {
					active.remove(id);
					activeCount--;
					state.finish(true);
				}
			case Request(id, method, timeoutMs, bytes):
				// Enforce monotonically increasing ids, preventing duplicate execution.
				if (id <= lastRequestId) {
					closeWith(ProtocolViolation("duplicate_request"));
					return;
				}
				lastRequestId = id;
				var handler = handlers.get(methodKey(method));
				if (handler == null) {
					enqueue(Failed(id, RpcProtocol.errorToWire(UnknownMethod)));
					return;
				}
				if (activeCount >= maxCalls) {
					enqueue(Failed(id, RpcProtocol.errorToWire(Busy)));
					return;
				}
				var state = new RpcRequestState(id, clock() + timeoutMs, clock);
				active.set(id, state);
				activeCount++;
				try
					handler(bytes, state)
				catch (_:Dynamic) {
					finish(state, Bytes.alloc(0), HandlerFailed);
				}
			case Notification(method, bytes):
				var handler = notifications.get(method);
				if (handler != null)
					handler(bytes);
			default:
				closeWith(ProtocolViolation("unexpected_handshake")); // Forbidden after establishment.
		}
	}

	/** Registers a service implementation. Haxeon generates dispatch and codecs for the supplied interface. */
	public extern function serve<Service>(service:#if haxe_ver Class < Service > #else Dynamic #end,
			implementation:Service):Void;

	/**
		Returns a client stub whose methods take one request and return a `Future<Result<Response, RpcError>>`, as `call`
		does. Haxeon generates the stub and codecs for the supplied interface. The default timeout is 1000 milliseconds.
	 */
	public extern function of<Service>(service:#if haxe_ver Class < Service > #else Dynamic #end,
			?timeoutMs:Int):Dynamic;
}
