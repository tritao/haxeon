package haxeon.wire;

import haxe.io.Bytes;
import haxeon.wire.MessagePackCodec;
import haxeon.wire.MessagePackReader;
import haxeon.wire.MessagePackWriter;

/**
	Compiler-owned entry point for typed MessagePack codecs.

	The static encode/decode calls are recognized by the Haxeon typer and lowered
	to generated, type-specific functions. The explicit codec helpers below are
	the escape hatch for values that do not fit the compiler-owned wire profile.
 */
class MessagePack {
	public static function encodeWith<T>(value:T, codec:MessagePackCodec<T>):Bytes {
		var writer = new MessagePackWriter();
		codec.encode(writer, value);
		return writer.getBytes();
	}

	/** Decodes one MessagePack value with `codec`, which fails the decode by throwing a `WireFailure`. */
	public static function decodeWith<T>(bytes:Bytes, codec:MessagePackCodec<T>):Result<T, WireError>
		return WireFailure.settle(input -> {
			var reader = new MessagePackReader(input);
			var value = codec.decode(reader);
			reader.requireEnd();
			value;
		}, bytes);

	/** Encodes a value as MessagePack. Haxeon generates the codec for the value's concrete type. */
	public static function encode<T>(value:T):Bytes
		throw new haxe.Exception("MessagePack.encode must be lowered by the compiler");

	/**
	 * Decodes one MessagePack value, or gives why the bytes are not one. Haxeon generates the codec from the expected result
	 * type: `var user:Result<User, WireError> = MessagePack.decode(bytes)`, or `var user:User = try MessagePack.decode(bytes)`.
	 */
	public static function decode<T>(bytes:Bytes):Result<T, WireError>
		throw new haxe.Exception("MessagePack.decode must be lowered by the compiler");
}
