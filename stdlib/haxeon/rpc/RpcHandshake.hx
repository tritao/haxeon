package haxeon.rpc;

import haxe.io.Bytes;

/** One bounded, nonblocking handshake. Rejection waits for peer close or deadline
 * after sending Refused, so accepted bytes are not discarded by abrupt close. */
class RpcHandshake {
	public var connection(default, null):Null<RpcConnection>;
	public var failure(default, null):Null<RpcError>;
	public var remoteApplication(default, null):Null<String>;
	public final deadline:Float;

	final transport:MessageTransport;
	final clock:Void->Float;
	final options:RpcPeerOptions;
	final initiator:Bool;
	final offered:Array<String>;
	final authorize:Null<(String, Array<String>) -> Null<RpcError>>;
	var negotiated:Array<String> = [];
	var outgoing:Null<Bytes>;
	var helloSent:Bool = false;
	var accepted:Bool = false;
	var refusalSent:Bool = false;
	var done:Bool = false;

	private function new(transport:MessageTransport, clock:Void->Float, options:RpcPeerOptions, initiator:Bool, offered:Array<String>,
			authorize:Null<(String, Array<String>) -> Null<RpcError>>) {
		this.transport = transport;
		this.clock = clock;
		this.options = options;
		this.initiator = initiator;
		this.offered = offered.copy();
		this.authorize = authorize;
		deadline = clock() + options.timeoutMs;
		if (initiator)
			outgoing = RpcProtocol.encode(Hello(options.protocol, options.codec, options.application, offered), options.maxMessageBytes);
	}

	public static function client(transport:MessageTransport, clock:Void->Float, options:RpcPeerOptions, offered:Array<String>):RpcHandshake {
		for (capability in offered)
			if (options.offered().indexOf(capability) < 0)
				throw "Handshake cannot widen policy";
		return new RpcHandshake(transport, clock, options, true, offered, null);
	}

	/** Authorization authenticates application-level policy; transport authentication
	 * must be completed by the adapter before this handshake is constructed. */
	public static function server(transport:MessageTransport, clock:Void->Float, options:RpcPeerOptions,
			?authorize:(String, Array<String>) -> Null<RpcError>):RpcHandshake {
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

	function fail(code:String):Void {
		failure = {code: code, message: code, ambiguous: false};
		close();
	}

	function reject(error:RpcError):Void {
		failure = error;
		outgoing = RpcProtocol.encode(Refused(error), options.maxMessageBytes);
	}

	function negotiate(protocol:Int, codec:Int, application:String, capabilities:Array<String>):Bool {
		var code:Null<String> = protocol != options.protocol ? "unsupported_protocol" : codec != options.codec ? "unsupported_codec" : null;
		if (code != null) {
			if (initiator)
				fail(code);
			else
				reject({code: code, message: code, ambiguous: false});
			return false;
		}
		remoteApplication = application;
		if (initiator) {
			for (capability in capabilities)
				if (offered.indexOf(capability) < 0) {
					fail("capability_widening");
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
				if (initiator)
					fail("missing_capability");
				else
					reject({code: "missing_capability", message: "missing_capability", ambiguous: false});
				return false;
			}
		return true;
	}

	function establish():Void {
		connection = new RpcConnection(transport, clock, options.maxMessageBytes, options.maxCalls, options.maxQueuedBytes);
		done = true;
	}

	public function poll():Void {
		if (done)
			return;
		if (!transport.isOpen()) {
			if (failure == null)
				failure = {code: "disconnected", message: "disconnected", ambiguous: false};
			close();
			return;
		}
		if (clock() >= deadline) {
			if (failure == null)
				failure = {code: "handshake_timeout", message: "handshake_timeout", ambiguous: false};
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
		var message:RpcEnvelope;
		try
			message = RpcProtocol.decode(bytes, options.maxMessageBytes)
		catch (_:Dynamic) {
			fail("invalid_handshake");
			return;
		}
		switch message {
			case Welcome(protocol, codec, application, capabilities) if (initiator && helloSent):
				if (negotiate(protocol, codec, application, capabilities))
					establish();
			case Refused(error) if (initiator && helloSent):
				failure = error;
				close();
			case Hello(protocol, codec, application, capabilities) if (!initiator):
				if (!negotiate(protocol, codec, application, capabilities))
					return;
				var policy = authorize;
				if (policy != null) {
					var refusal:Null<RpcError>;
					try
						refusal = policy(application, negotiated.copy())
					catch (_:Dynamic) {
						reject({code: "authorization_failed", message: "authorization_failed", ambiguous: false});
						return;
					}
					if (refusal != null) {
						reject(refusal);
						return;
					}
				}
				accepted = true;
				outgoing = RpcProtocol.encode(Welcome(options.protocol, options.codec, options.application, negotiated), options.maxMessageBytes);
			default:
				fail("invalid_handshake");
		}
	}
}
