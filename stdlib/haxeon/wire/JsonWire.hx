package haxeon.wire;

/** Compiler-generated JSON codec for the same @:wire schema as MessagePack. */
class JsonWire {
	/** Explicit codec escape hatch for types outside the generated profile. */
	public static function encodeWith<T>(value:T, codec:JsonWireCodec<T>):String {
		var writer = new JsonWireWriter();
		codec.encode(writer, value);
		return writer.getString();
	}

	public static function decodeWith<T>(source:String, codec:JsonWireCodec<T>):T {
		var reader = new JsonWireReader(source);
		var value = codec.decode(reader);
		if (!reader.atEnd())
			throw "JSON value has trailing content";
		return value;
	}

	/** Encodes a value as JSON. Haxeon generates the codec for the value's concrete type. */
	public static function encode<T>(value:T):String
		throw new haxe.Exception("JsonWire.encode must be lowered by the compiler");

	/** Decodes one JSON value. Haxeon generates the codec from the expected result type. */
	public static function decode<T>(source:String):T
		throw new haxe.Exception("JsonWire.decode must be lowered by the compiler");
}
