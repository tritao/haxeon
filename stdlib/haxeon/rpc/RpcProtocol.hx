package haxeon.rpc;

import haxe.io.Bytes;
import haxeon.wire.MessagePack;

/** Framing/codec versions are independent of the application's version string. */
class RpcProtocol {
	public static inline final VERSION:Int = 1;
	public static inline final CODEC_VERSION:Int = 1;
	public static inline final MAX_CAPABILITIES:Int = 64;

	public static function encode(message:RpcEnvelope, maxBytes:Int):Bytes {
		validate(message);
		var encoded = MessagePack.encode(message);
		if (encoded.length > maxBytes)
			throw "RPC message exceeds configured limit";
		return encoded;
	}

	public static function decode(bytes:Bytes, maxBytes:Int):RpcEnvelope {
		if (bytes == null || bytes.length > maxBytes)
			throw "RPC message exceeds configured limit";
		var message:RpcEnvelope = MessagePack.decode(bytes);
		validate(message);
		return message;
	}

	public static function validate(message:RpcEnvelope):Void {
		if (message == null)
			throw "RPC envelope is required";
		switch message {
			case Hello(protocol, codec, application, capabilities), Welcome(protocol, codec, application, capabilities):
				if (protocol <= 0 || codec <= 0 || application == null || application.length == 0 || application.length > 256)
					throw "Invalid RPC handshake";
				if (capabilities == null || capabilities.length > MAX_CAPABILITIES)
					throw "Invalid RPC capabilities";
				var seen:Map<String, Bool> = [];
				for (capability in capabilities) {
					if (capability == null || capability.length == 0 || capability.length > 128 || seen.exists(capability))
						throw "Invalid or duplicate RPC capability";
					seen.set(capability, true);
				}
			case Request(id, method, timeoutMs, payload):
				if (id <= 0 || method <= 0 || timeoutMs <= 0 || payload == null)
					throw "Invalid RPC request";
			case Response(id, payload):
				if (id <= 0 || payload == null)
					throw "Invalid RPC response";
			case Failed(id, error):
				if (id <= 0)
					throw "Invalid RPC response id";
				validateError(error);
			case Cancel(id):
				if (id <= 0)
					throw "Invalid RPC cancellation id";
			case Notification(method, payload):
				if (method <= 0 || payload == null)
					throw "Invalid RPC notification";
			case Refused(error):
				validateError(error);
		}
	}

	static function validateError(error:RpcError):Void {
		if (error == null || error.code == null || error.code.length == 0 || error.code.length > 128 || error.message == null || error.message.length > 4096)
			throw "Invalid RPC error";
	}
}
