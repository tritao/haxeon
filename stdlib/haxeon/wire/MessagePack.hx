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

	public static function decodeWith<T>(bytes:Bytes, codec:MessagePackCodec<T>):T {
		var reader = new MessagePackReader(bytes);
		var value = codec.decode(reader);
		if (!reader.atEnd())
			throw new MessagePackError("MessagePack value has trailing bytes");
		return value;
	}

	/** Encodes a value as MessagePack. Haxeon generates the codec for the value's concrete type. */
	public static function encode<T>(value:T):Bytes
		throw new haxe.Exception("MessagePack.encode must be lowered by the compiler");

	/** Decodes one MessagePack value. Haxeon generates the codec from the expected result type. */
	public static function decode<T>(bytes:Bytes):T
		throw new haxe.Exception("MessagePack.decode must be lowered by the compiler");
}
