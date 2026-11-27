package haxeon.wire;

/** Compiler-generated JSON codec for the same @:wire schema as MessagePack. */
class JsonWire {
	/** Explicit codec escape hatch for types outside the generated profile. */
	public static function encodeWith<T>(value:T, codec:JsonWireCodec<T>):String {
		var writer = new JsonWireWriter();
		codec.encode(writer, value);
		return writer.getString();
	}

	/** Decodes one JSON value with `codec`, which fails the decode by throwing a `WireFailure`. */
	public static function decodeWith<T>(source:String, codec:JsonWireCodec<T>):Result<T, WireError>
		return WireFailure.settle(input -> {
			var reader = new JsonWireReader(input);
			var value = codec.decode(reader);
			reader.requireEnd();
			value;
		}, source);

	/** Encodes a value as JSON. Haxeon generates the codec for the value's concrete type. */
	public static extern function encode<T>(value:T):String;

	/** Decodes one JSON value, or gives why the source is not one. Haxeon generates the codec from the expected result type. */
	public static extern function decode<T>(source:String):Result<T, WireError>;
}
