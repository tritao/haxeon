package haxeon.rpc;

import haxe.io.Bytes;
import haxeon.wire.MessagePack;
import haxeon.wire.WireError;

/** Framing/codec versions are independent of the application's version string. */
internal class RpcProtocol {
	public static inline final VERSION:Int = 2;
	public static inline final CODEC_VERSION:Int = 1;
	public static inline final MAX_CAPABILITIES:Int = 64;

	/** Throws for `message` when it is not a valid envelope: one this side should not make. */
	public static function validate(message:RpcEnvelope):Void {
		var invalid = problem(message);
		if (invalid != null)
			throw new haxe.Exception(invalid);
	}

	/** `message` encoded, at most `maxBytes` long. Throws for a message this side should not have made. */
	public static function encode(message:RpcEnvelope, maxBytes:Int):Bytes {
		validate(message);
		var encoded = MessagePack.encode(message);
		if (encoded.length > maxBytes)
			throw new haxe.Exception("RPC message exceeds configured limit");
		return encoded;
	}

	/** The envelope `bytes` hold, or why they are not one: too long, not an envelope, or one no peer may send. */
	public static function decode(bytes:Bytes, maxBytes:Int):Result<RpcEnvelope, WireError> {
		if (bytes.length > maxBytes)
			return Err(LimitExceeded("RPC message exceeds configured limit"));
		return switch MessagePack.decode<RpcEnvelope>(bytes) {
			case Ok(message):
				var invalid = problem(message);
				invalid == null ? Ok(message) : Err(Malformed(invalid));
			case Err(error): Err(error);
		};
	}

	/** What is wrong with `message`, or null when it is a valid envelope. */
	static function problem(message:RpcEnvelope):Null<String> {
		if (message == null)
			return "RPC envelope is required";
		switch message {
			case Hello(protocol, codec, application, capabilities), Welcome(protocol, codec, application, capabilities):
				if (protocol <= 0 || codec <= 0 || application == null || application.length == 0
					|| application.length > 256)
					return "Invalid RPC handshake";
				if (capabilities == null || capabilities.length > MAX_CAPABILITIES)
					return "Invalid RPC capabilities";
				var seen:Map<String, Bool> = [];
				for (capability in capabilities) {
					if (capability == null || capability.length == 0 || capability.length > 128
						|| seen.exists(capability))
						return "Invalid or duplicate RPC capability";
					seen.set(capability, true);
				}
			case Request(id, method, timeoutMs, payload):
				var valid = switch method {
					case null: false;
					case Id(id): id > 0;
					case Name(name): name != null && name.length > 0;
					case ServiceId(service, id): service != null && service.length > 0 && id > 0;
				};
				if (id <= 0 || !valid || timeoutMs <= 0 || payload == null)
					return "Invalid RPC request";
			case Response(id, payload):
				if (id <= 0 || payload == null)
					return "Invalid RPC response";
			case Failed(id, error):
				if (id <= 0)
					return "Invalid RPC response id";
				return errorProblem(error);
			case Cancel(id):
				if (id <= 0)
					return "Invalid RPC cancellation id";
			case Notification(method, payload):
				if (method <= 0 || payload == null)
					return "Invalid RPC notification";
			case Refused(error):
				return errorProblem(error);
		}
		return null;
	}

	/** `error` as the wire carries it. */
	public static function errorToWire(error:RpcError):RpcErrorData
		return {code: error.code(), message: errorMessage(error), ambiguous: error.mayHaveRun()};

	static function errorMessage(error:RpcError):String
		return switch error {
			case ConnectFailed(text, _), HandshakeFailed(text), AuthorizationFailed(text), MissingCapability(text),
				ProtocolViolation(text), Remote(_, text, _): text;
			default: error.code();
		};

	/** The error a peer sent as `data`: the case its code names, or `Remote` for a code of the peer's own. */
	public static function errorFromWire(data:RpcErrorData):RpcError
		return switch data.code {
			case "disconnected": Disconnected(data.ambiguous);
			case "busy": Busy;
			case "timeout": TimedOut(data.ambiguous);
			case "unknown_method": UnknownMethod;
			case "invalid_request": InvalidRequest;
			case "handler_failed": HandlerFailed;
			case "cancelled": HandlerCancelled;
			case "stopped": HandlerStopped;
			case "authorization_failed": AuthorizationFailed(data.message);
			case "missing_capability": MissingCapability(data.message);
			case "unsupported_protocol", "unsupported_codec", "capability_widening", "invalid_handshake":
				HandshakeFailed(data.code);
			default: Remote(data.code, data.message, data.ambiguous);
		};

	static function errorProblem(error:RpcErrorData):Null<String>
		return error == null || error.code == null || error.code.length == 0 || error.code.length > 128
			|| error.message == null || error.message.length > 4096 ? "Invalid RPC error" : null;
}
