package haxeon.rpc;

import haxe.io.Bytes;

/** One bounded, nonblocking handshake. Rejection waits for peer close or deadline
 * after sending Refused, so accepted bytes are not discarded by abrupt close. */
internal class RpcHandshake {
	public var connection(default, null):Null<RpcConnection>;
	public var failure(default, null):Null<RpcError>;
	public var remoteApplication(default, null):Null<String>;
	public final deadline:Float;

	final transport:MessageTransport;
	final clock:Void->Float;
	final options:RpcPeerOptions;
	final initiator:Bool;
	final offered:Array<String>;
	final authorize:Null<(String, Array<String>) -> Result<Void, RpcError>>;
	var negotiated:Array<String> = [];
	var outgoing:Null<Bytes>;
	var helloSent:Bool = false;
	var accepted:Bool = false;
	var refusalSent:Bool = false;
	var done:Bool = false;

	private function new(transport:MessageTransport, clock:Void->Float, options:RpcPeerOptions, initiator:Bool,
			offered:Array<String>,
			authorize:Null<(String, Array<String>) -> Result<Void, RpcError>>) {
		this.transport = transport;
		this.clock = clock;
		this.options = options;
		this.initiator = initiator;
		this.offered = offered.copy();
		this.authorize = authorize;
		deadline = clock() + options.timeoutMs;
		if (initiator)
			outgoing = RpcProtocol.encode(Hello(RpcProtocol.VERSION, RpcProtocol.CODEC_VERSION, options.application,
				offered),
				options.maxMessageBytes);
	}

	public static function client(transport:MessageTransport, clock:Void->Float, options:RpcPeerOptions,
			offered:Array<String>):RpcHandshake {
		for (capability in offered)
			if (options.offered().indexOf(capability) < 0)
				throw new haxe.Exception("Handshake cannot widen policy");
		return new RpcHandshake(transport, clock, options, true, offered, null);
	}

	/** Authorization authenticates application-level policy: `authorize` takes the peer's application and the agreed
	 * capabilities, and refuses with an error (usually `AuthorizationFailed(reason)`). Transport authentication must be
	 * completed by the adapter before this handshake is constructed. */
	public static function server(transport:MessageTransport, clock:Void->Float, options:RpcPeerOptions,
			?authorize:(String, Array<String>) -> Result<Void, RpcError>):RpcHandshake {
		return new RpcHandshake(transport, clock, options, false, options.offered(), authorize);
	}

	public function isFinished():Bool
		return done;

	public function capabilities():Array<String>
		return negotiated.copy();

	public function close():Void {
		outgoing = null;
		done = true;
		if (connection != null)
			connection.close();
		else
			transport.close();
	}

	function fail(error:RpcError):Void {
		failure = error;
		close();
	}

	function reject(error:RpcError):Void {
		failure = error;
		outgoing = RpcProtocol.encode(Refused(RpcProtocol.errorToWire(error)), options.maxMessageBytes);
	}

	/** Fails the handshake with `error`: the client closes, and the server refuses the client with it. */
	function refuse(error:RpcError):Void {
		if (initiator)
			fail(error);
		else
			reject(error);
	}

	function negotiate(protocol:Int, codec:Int, application:String, capabilities:Array<String>):Bool {
		if (protocol != RpcProtocol.VERSION || codec != RpcProtocol.CODEC_VERSION) {
			refuse(HandshakeFailed(protocol != RpcProtocol.VERSION ? "unsupported_protocol" : "unsupported_codec"));
			return false;
		}
		remoteApplication = application;
		if (initiator) {
			for (capability in capabilities)
				if (offered.indexOf(capability) < 0) {
					fail(HandshakeFailed("capability_widening"));
					return false;
				}
			negotiated = capabilities.copy();
		} else {
			negotiated = [
				for (capability in offered) if (capabilities.indexOf(capability) >= 0) capability
			];
		}
		for (capability in options.requirements())
			if (negotiated.indexOf(capability) < 0) {
				refuse(MissingCapability(capability));
				return false;
			}
		return true;
	}

	function establish():Void {
		connection = new RpcConnection(transport, clock, options.maxMessageBytes, options.maxCalls,
			options.maxQueuedBytes);
		done = true;
	}

	public function poll():Void {
		if (done)
			return;
		if (!transport.isOpen()) {
			if (failure == null)
				failure = Disconnected(false);
			close();
			return;
		}
		if (clock() >= deadline) {
			if (failure == null)
				failure = HandshakeTimeout;
			close();
			return;
		}
		var bytes = outgoing;
		if (bytes != null) {
			if (!transport.send(bytes))
				return;
			outgoing = null;
			if (initiator)
				helloSent = true;
			else if (accepted) {
				establish();
				return;
			} else {
				refusalSent = true;
				return;
			}
		}
		if (refusalSent)
			return;
		bytes = transport.receive();
		if (bytes == null)
			return;
		var message = switch RpcProtocol.decode(bytes, options.maxMessageBytes) {
			case Ok(message): message;
			case Err(_):
				fail(HandshakeFailed("invalid_handshake"));
				return;
		};
		switch message {
			case Welcome(protocol, codec, application, capabilities) if (initiator && helloSent):
				if (negotiate(protocol, codec, application, capabilities))
					establish();
			case Refused(error) if (initiator && helloSent):
				failure = RpcProtocol.errorFromWire(error);
				close();
			case Hello(protocol, codec, application, capabilities) if (!initiator):
				if (!negotiate(protocol, codec, application, capabilities))
					return;
				var policy = authorize;
				if (policy != null) {
					var decision:Result<Void, RpcError>;
					try
						decision = policy(application, negotiated.copy())
					catch (_:Dynamic) {
						reject(AuthorizationFailed("the authorization policy failed"));
						return;
					}
					switch decision {
						case Ok():
						case Err(refusal):
							reject(refusal);
							return;
					}
				}
				accepted = true;
				outgoing = RpcProtocol.encode(Welcome(RpcProtocol.VERSION, RpcProtocol.CODEC_VERSION,
					options.application, negotiated),
					options.maxMessageBytes);
			default:
				fail(HandshakeFailed("invalid_handshake"));
		}
	}
}
