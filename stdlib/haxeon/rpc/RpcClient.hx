package haxeon.rpc;

/** Poll supplies scheduling; nextWakeAt lets a host arm its own cancellable timer.
 * Every attempt has a generation. No calls or resource-creating requests replay. */
class RpcClient {
	public var state(default, null):RpcClientState = Disconnected;
	public var generation(default, null):Int = 0;
	public var lastError(default, null):Null<RpcError>;
	public var remoteApplication(default, null):Null<String>;

	final connector:RpcConnector;
	final clock:Void->Float;
	final random:Void->Float;
	final options:RpcPeerOptions;
	final ready:(RpcConnection, Int, Array<String>) -> Void;
	final baseBackoffMs:Int;
	final maxBackoffMs:Int;
	final connectTimeoutMs:Int;
	var ceiling:Array<String>;
	var retryStep:Float;
	var retryAt:Float;
	var connectDeadline:Float = 0;
	var connectedAt:Float = 0;
	var attempt:Null<RpcConnectAttempt>;
	var handshake:Null<RpcHandshake>;
	var connection:Null<RpcConnection>;
	var activeTransport:Null<MessageTransport>;
	var polling:Bool = false;

	public function new(connector:RpcConnector, clock:Void->Float, random:Void->Float, options:RpcPeerOptions,
			ready:(RpcConnection, Int, Array<String>) -> Void, baseBackoffMs:Int = 100, maxBackoffMs:Int = 10000, connectTimeoutMs:Int = 10000) {
		if (baseBackoffMs < 1 || maxBackoffMs < baseBackoffMs || connectTimeoutMs < 1)
			throw "Invalid RPC reconnect limits";
		this.connector = connector;
		this.clock = clock;
		this.random = random;
		this.options = options;
		this.ready = ready;
		this.baseBackoffMs = baseBackoffMs;
		this.maxBackoffMs = maxBackoffMs;
		this.connectTimeoutMs = connectTimeoutMs;
		ceiling = options.offered();
		retryStep = baseBackoffMs;
		retryAt = clock();
	}

	public function current():Null<RpcConnection>
		return state == Connected && connection != null && connection.isOpen() ? connection : null;

	public function capabilities():Array<String>
		return state == Connected ? ceiling.copy() : [];

	/** Fence application work deferred from the explicit ready/resume hook. */
	public function isCurrent(token:Int):Bool
		return token == generation && current() != null;

	public function nextWakeAt():Null<Float> {
		return switch state {
			case Disconnected: retryAt;
			case Connecting: connectDeadline;
			case Handshaking: handshake == null ? null : handshake.deadline;
			case Connected: connection == null ? null : connection.nextDeadline();
			case Closed: null;
		};
	}

	public function close():Void {
		if (state == Closed)
			return;
		state = Closed;
		var pending = attempt;
		attempt = null;
		var negotiating = handshake;
		handshake = null;
		var established = connection;
		connection = null;
		var transport = activeTransport;
		activeTransport = null;
		if (pending != null)
			pending.cancel();
		if (negotiating != null)
			negotiating.close();
		if (established != null)
			established.close();
		else if (negotiating == null && transport != null)
			transport.close();
	}

	static function terminal(code:String):Bool {
		return code == "unauthorized" || code == "authentication_refused" || code == "authorization_failed" || code == "unsupported_protocol"
			|| code == "unsupported_codec" || code == "missing_capability" || code == "capability_widening" || code == "invalid_handshake"
			|| code == "invalid_envelope" || code == "invalid_notification" || code == "duplicate_request" || code == "unexpected_handshake"
			|| code == "oversized_message";
	}

	function failed(error:RpcError, retryable:Bool):Void {
		lastError = error;
		if (!retryable || terminal(error.code)) {
			close();
			return;
		}
		var sample:Float;
		try
			sample = random()
		catch (failure:Dynamic) {
			close();
			throw failure;
		}
		if (!Math.isFinite(sample) || sample < 0 || sample > 1) {
			close();
			throw "RPC random source must return a value in [0,1]";
		}
		state = Disconnected;
		var pending = attempt;
		attempt = null;
		var negotiating = handshake;
		handshake = null;
		var established = connection;
		connection = null;
		var transport = activeTransport;
		activeTransport = null;
		if (pending != null)
			pending.cancel();
		if (negotiating != null)
			negotiating.close();
		retryAt = clock() + retryStep * (0.5 + 0.5 * sample);
		retryStep = Math.min(maxBackoffMs, retryStep * 2);
		if (established != null)
			established.close();
		else if (negotiating == null && transport != null)
			transport.close();
	}

	function start():Void {
		if (generation == 0x7fffffff) {
			failed({code: "generation_exhausted", message: "generation_exhausted", ambiguous: false}, false);
			return;
		}
		generation++;
		var token = generation;
		state = Connecting;
		connectDeadline = clock() + connectTimeoutMs;
		var pending:RpcConnectAttempt;
		try
			pending = connector.connect(function(result) {
				if (generation != token || state != Connecting || clock() >= connectDeadline) {
					switch result {
						case Opened(transport):
							if (transport != activeTransport)
								transport.close();
						case Failed(_, _):
					}
					return;
				}
				attempt = null;
				switch result {
					case Opened(transport):
						if (!transport.isOpen()) {
							failed({code: "disconnected", message: "disconnected", ambiguous: false}, true);
							return;
						}
						activeTransport = transport;
						handshake = RpcHandshake.client(transport, clock, options, ceiling);
						state = Handshaking;
					case Failed(error, retryable):
						failed(error, retryable);
				}
			})
		catch (error:Dynamic) {
			if (generation != token || state != Connecting)
				throw error;
			failed({code: "connect_failed", message: "connect_failed", ambiguous: false}, true);
			return;
		}
		if (generation == token && state == Connecting)
			attempt = pending;
		else
			pending.cancel();
	}

	public function poll(messageBudget:Int = 32, ?byteBudget:Int):Void {
		var bytes = byteBudget == null ? options.maxMessageBytes : byteBudget;
		if (messageBudget < 1 || bytes < options.maxMessageBytes)
			throw "Invalid RPC client poll budget";
		if (polling)
			throw "RPC client poll is not reentrant";
		polling = true;
		try
			pollInternal(messageBudget, bytes)
		catch (error:Dynamic) {
			polling = false;
			throw error;
		}
		polling = false;
	}

	function pollInternal(messageBudget:Int, byteBudget:Int):Void {
		switch state {
			case Disconnected:
				if (clock() >= retryAt)
					start();
			case Connecting:
				if (clock() >= connectDeadline)
					failed({code: "connect_timeout", message: "connect_timeout", ambiguous: false}, true);
			case Handshaking:
				var negotiating = handshake;
				if (negotiating == null)
					throw "Missing RPC handshake";
				negotiating.poll();
				if (negotiating.isFinished()) {
					var established = negotiating.connection;
					if (established == null) {
						var failure = negotiating.failure;
						failed(failure == null ? {code: "handshake_failed", message: "handshake_failed",
							ambiguous: false} : failure, failure == null || failure.code == "disconnected" || failure.code == "handshake_timeout");
					} else {
						handshake = null;
						connection = established;
						ceiling = negotiating.capabilities();
						remoteApplication = negotiating.remoteApplication;
						state = Connected;
						connectedAt = clock();
						lastError = null;
						ready(established, generation, ceiling.copy());
					}
				}
			case Connected:
				var established = connection;
				if (established == null)
					throw "Missing RPC connection";
				if (established.isOpen())
					established.poll(messageBudget, byteBudget);
				if (state != Connected || connection != established)
					return;
				if (!established.isOpen()) {
					if (clock() - connectedAt >= maxBackoffMs)
						retryStep = baseBackoffMs;
					var reason = established.closeReason;
					failed({code: reason == null ? "disconnected" : reason, message: reason == null ? "disconnected" : reason, ambiguous: false}, true);
				}
			case Closed:
		}
	}
}
