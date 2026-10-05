package haxeon.rpc;

import haxe.io.Bytes;

private typedef PendingCall = {
	var deadline:Float;
	var response:Bytes->Void;
	var failure:RpcError->Void;
}

/** One established connection generation. Handshake/reconnect belongs to its owner.
 * poll is nonblocking and bounded. Requests are sent once and never replayed.
 * Clock values and deadlines are monotonic milliseconds. */
class RpcConnection {
	public var closeReason(default, null):Null<String>;

	final transport:MessageTransport;
	final clock:Void->Float;
	final maxMessageBytes:Int;
	final maxCalls:Int;
	final maxQueuedBytes:Int;
	final handlers:Map<Int, (Bytes, RpcRequestState) -> Void> = [];
	final notifications:Map<Int, Bytes->Void> = [];
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

	public function new(transport:MessageTransport, clock:Void->Float, maxMessageBytes:Int = 4 * 1024 * 1024, maxCalls:Int = 256,
			maxQueuedBytes:Int = 8 * 1024 * 1024) {
		if (maxMessageBytes < 128
			|| maxCalls < 1
			|| maxQueuedBytes < maxMessageBytes
			|| maxQueuedBytes > 0x7fffffff - maxMessageBytes)
			throw "Invalid RPC connection limits";
		this.transport = transport;
		this.clock = clock;
		this.maxMessageBytes = maxMessageBytes;
		this.maxCalls = maxCalls;
		this.maxQueuedBytes = maxQueuedBytes;
	}

	public function isOpen():Bool
		return open && transport.isOpen();

	public function pendingCalls():Int
		return pendingCount;

	public function activeRequests():Int
		return activeCount;

	public function bufferedBytes():Int
		return queuedBytes + (held == null ? 0 : held.length);

	public function register<Request, Response>(method:RpcMethod<Request, Response>, handler:(Request, RpcContext<Response>) -> Void):Void {
		if (handlers.exists(method.id))
			throw "Duplicate RPC method id";
		handlers.set(method.id, function(payload, state) {
			var request:Request;
			try
				request = method.decodeRequest(payload)
			catch (_:Dynamic) {
				finish(state, Bytes.alloc(0), error("invalid_request", false));
				return;
			}
			var context = new RpcContext(state, method.encodeResponse, function(bytes, error) return finish(state, bytes, error));
			handler(request, context);
		});
	}

	public function onNotification<T>(id:Int, decode:Bytes->T, handler:T->Void):Void {
		if (id <= 0 || notifications.exists(id))
			throw "Invalid or duplicate notification id";
		notifications.set(id, function(bytes) {
			var value:T;
			try
				value = decode(bytes)
			catch (_:Dynamic) {
				close("invalid_notification");
				return;
			}
			handler(value);
		});
	}

	public function notify<T>(id:Int, value:T, encode:T->Bytes):Bool {
		if (!isOpen())
			return false;
		return enqueue(Notification(id, encode(value)));
	}

	/** Zero means definitely not dispatched. Positive ids may already have executed. */
	public function call<Request, Response>(method:RpcMethod<Request, Response>, request:Request, timeoutMs:Int, response:Response->Void,
			failure:RpcError->Void):Int {
		if (!isOpen()) {
			failure(error("disconnected", false));
			return 0;
		}
		if (timeoutMs <= 0)
			throw "RPC timeout must be positive";
		if (pendingCount >= maxCalls || nextId == 0x7fffffff || outgoing.length > 0) {
			failure(error("busy", false));
			return 0;
		}
		var id = nextId++;
		var deadline = clock() + timeoutMs;
		var bytes = RpcProtocol.encode(Request(id, method.id, timeoutMs, method.encodeRequest(request)), maxMessageBytes);
		if (clock() >= deadline) {
			failure(error("timeout", false));
			return 0;
		}
		if (!trySend(bytes)) {
			failure(error(isOpen() ? "busy" : "disconnected", false));
			return 0;
		}
		pending.set(id, {
			deadline: deadline,
			response: function(bytes) {
				var value:Response;
				try
					value = method.decodeResponse(bytes)
				catch (_:Dynamic) {
					failure(error("invalid_response", true));
					return;
				}
				response(value);
			},
			failure: failure
		});
		pendingCount++;
		return id;
	}

	public function cancel(id:Int):Bool {
		var call = takePending(id);
		if (call == null)
			return false;
		try
			enqueue(Cancel(id))
		catch (failure:Dynamic) {
			call.failure(error("cancelled", true));
			throw failure;
		}
		call.failure(error("cancelled", true));
		return true;
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
		var encoded = RpcProtocol.encode(failure == null ? Response(state.id, bytes) : Failed(state.id, failure), maxMessageBytes);
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
			close();
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

	public function close(reason:String = "disconnected"):Void {
		if (!open)
			return;
		open = false;
		closeReason = reason;
		transport.close();
		held = null;
		outgoing.resize(0);
		queuedBytes = 0;
		var calls = pending;
		pending = [];
		pendingCount = 0;
		for (state in active)
			state.finish(true);
		active = [];
		activeCount = 0;
		// One failing application callback must not strand the remaining waiters.
		var callbackError:Dynamic = null;
		var callbackFailed = false;
		for (call in calls)
			try
				call.failure(error(reason, true))
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
	public function poll(messageBudget:Int = 32, byteBudget:Int = 4 * 1024 * 1024):Int {
		if (polling)
			throw "RPC poll is not reentrant";
		if (messageBudget < 1 || byteBudget < maxMessageBytes)
			throw "Invalid RPC poll budget";
		polling = true;
		sendMessagesLeft = messageBudget;
		sendBytesLeft = byteBudget;
		var count:Int;
		try
			count = pollInternal(messageBudget, byteBudget)
		catch (failure:Dynamic) {
			polling = false;
			throw failure;
		}
		polling = false;
		return count;
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
			if (call != null) {
				try
					enqueue(Cancel(id))
				catch (failure:Dynamic) {
					call.failure(error("timeout", true));
					throw failure;
				}
				call.failure(error("timeout", true));
			}
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
				enqueue(Failed(id, error("timeout", true)));
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
				close("oversized_message");
				break;
			}
			if (bytes.length > byteBudget - used) {
				held = bytes;
				break;
			}
			held = null;
			used += bytes.length;
			count++;
			var message:RpcEnvelope;
			try
				message = RpcProtocol.decode(bytes, maxMessageBytes)
			catch (_:Dynamic) {
				close("invalid_envelope");
				break;
			}
			dispatch(message);
		}
		return count;
	}

	function dispatch(message:RpcEnvelope):Void {
		switch message {
			case Response(id, bytes):
				var call = takePending(id);
				if (call != null) {
					if (clock() >= call.deadline)
						call.failure(error("timeout", true));
					else
						call.response(bytes);
				}
			case Failed(id, failure):
				var call = takePending(id);
				if (call != null)
					call.failure(clock() >= call.deadline ? error("timeout", true) : failure);
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
					close("duplicate_request");
					return;
				}
				lastRequestId = id;
				var handler = handlers.get(method);
				if (handler == null) {
					enqueue(Failed(id, error("unknown_method", false)));
					return;
				}
				if (activeCount >= maxCalls) {
					enqueue(Failed(id, error("busy", false)));
					return;
				}
				var state = new RpcRequestState(id, clock() + timeoutMs, clock);
				active.set(id, state);
				activeCount++;
				try
					handler(bytes, state)
				catch (_:Dynamic) {
					finish(state, Bytes.alloc(0), error("handler_failed", true));
				}
			case Notification(method, bytes):
				var handler = notifications.get(method);
				if (handler != null)
					handler(bytes);
			default:
				close("unexpected_handshake"); // Forbidden after establishment.
		}
	}

	static function error(code:String, ambiguous:Bool):RpcError
		return {code: code, message: code, ambiguous: ambiguous};
}
