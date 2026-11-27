package haxeon.rpc;

/**
 * The client side of an RPC peer: connects through its connector, handshakes, and reconnects with backoff when the
 * connection drops. It does nothing by itself: `poll` does the work, and `nextWakeAt` says when to poll next, for a host to
 * arm its own timer. Each connection attempt has a new generation; no call or resource-creating request is replayed on a
 * new connection.
 */
class RpcClient {
	/** Where the client is in connecting. */
	public var state(default, null):RpcClientState = Disconnected;

	/**
	 * The number of the current connection attempt, which each new attempt advances: what `isCurrent` compares a token
	 * with.
	 */
	public var generation(default, null):Int = 0;

	/** Why the last connection failed or dropped, or null. */
	public var lastError(default, null):Null<RpcError>;

	/** The application name the peer gave in the handshake, once connected. */
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

	/**
	 * A client connecting through `connector`, with `clock` giving the time in milliseconds and `random` a value in [0,
	 * 1) for the backoff's jitter. `ready` is called with each new connection, its generation and the capabilities
	 * agreed. Retries wait from `baseBackoffMs`, doubling up to `maxBackoffMs`; an attempt gives up after
	 * `connectTimeoutMs`.
	 */
	public function new(connector:RpcConnector, clock:Void->Float, random:Void->Float, options:RpcPeerOptions,
			ready:(RpcConnection, Int, Array<String>) -> Void, baseBackoffMs:Int = 100, maxBackoffMs:Int = 10000,
			connectTimeoutMs:Int = 10000) {
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

	/** The open connection, or null when the client is not connected. */
	public function current():Null<RpcConnection>
		return state == Connected && connection != null && connection.isOpen() ? connection : null;

	/** The capabilities the handshake agreed on, while connected; empty otherwise. */
	public function capabilities():Array<String>
		return state == Connected ? ceiling.copy() : [];

	/** Fence application work deferred from the explicit ready/resume hook. */
	public function isCurrent(token:Int):Bool
		return token == generation && current() != null;

	/**
	 * When `poll` next has work, in `clock` time: the next retry, the attempt's or handshake's deadline, or the
	 * connection's next request deadline. Null when there is none.
	 */
	public function nextWakeAt():Null<Float> {
		return switch state {
			case Disconnected: retryAt;
			case Connecting: connectDeadline;
			case Handshaking: handshake == null ? null : handshake.deadline;
			case Connected: connection == null ? null : connection.nextDeadline();
			case Closed: null;
		};
	}

	/**
		Retries now instead of waiting out the backoff, for a host that learned the network is back or changed. A client that is
		waiting to retry (Disconnected) dials at the next poll with the backoff reset. With `redial`, a client that is connecting,
		handshaking or connected is dropped first, because its socket belongs to the old network and is dead; without it only a
		client that is waiting is touched, so a healthy connection survives. A closed client stays closed (its error was terminal).
	**/
	public function retryNow(redial:Bool = false):Void {
		if (state == Closed)
			return;
		if (state != Disconnected) {
			if (!redial)
				return;
			failed(new RpcError("network_changed", "network_changed", false), true);
			if (state == Closed)
				return;
		}
		retryStep = baseBackoffMs;
		retryAt = clock();
	}

	/** Closes the client for good: abandons an attempt, closes the connection, and never connects again. */
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
		return code == "unauthorized" || code == "authentication_refused" || code == "authorization_failed"
			|| code == "unsupported_protocol"
			|| code == "unsupported_codec" || code == "missing_capability" || code == "capability_widening"
			|| code == "invalid_handshake"
			|| code == "invalid_envelope" || code == "invalid_notification" || code == "duplicate_request"
			|| code == "unexpected_handshake"
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
			failed(new RpcError("generation_exhausted", "generation_exhausted", false), false);
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
							failed(new RpcError("disconnected", "disconnected", false), true);
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
			failed(new RpcError("connect_failed", "connect_failed", false), true);
			return;
		}
		if (generation == token && state == Connecting)
			attempt = pending;
		else
			pending.cancel();
	}

	/**
	 * Does the client's pending work: connects or retries when it is time, handshakes, and handles up to
	 * `messageBudget` messages and `byteBudget` bytes of the connection. Throws when called from inside itself.
	 */
	public function poll(messageBudget:Int = 32, ?byteBudget:Int):Void {
		var bytes = byteBudget == null ? options.maxMessageBytes : byteBudget;
		if (messageBudget < 1 || bytes < options.maxMessageBytes)
			throw "Invalid RPC client poll budget";
		if (polling)
			throw "RPC client poll is not reentrant";
		polling = true;
		defer polling = false;
		pollInternal(messageBudget, bytes);
	}

	function pollInternal(messageBudget:Int, byteBudget:Int):Void {
		switch state {
			case Disconnected:
				if (clock() >= retryAt)
					start();
			case Connecting:
				if (clock() >= connectDeadline)
					failed(new RpcError("connect_timeout", "connect_timeout", false), true);
			case Handshaking:
				var negotiating = handshake;
				if (negotiating == null)
					throw "Missing RPC handshake";
				negotiating.poll();
				if (negotiating.isFinished()) {
					var established = negotiating.connection;
					if (established == null) {
						var failure = negotiating.failure;
						failed(failure == null ? new RpcError("handshake_failed", "handshake_failed", false) : failure,
							failure == null || failure.code == "disconnected" || failure.code == "handshake_timeout");
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
					failed(new RpcError(reason == null ? "disconnected" : reason,
						reason == null ? "disconnected" : reason, false), true);
				}
			case Closed:
		}
	}
}
