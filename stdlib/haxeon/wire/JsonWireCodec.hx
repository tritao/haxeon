package haxeon.wire;

/** A codec written by hand, for a type outside what the compiler generates JSON codecs for (`JsonWire.encodeWith`). */
interface JsonWireCodec<T> {
	/** Writes `value` to `writer`. */
	function encode(writer:JsonWireWriter, value:T):Void;

	/** Reads a value from `reader`; throws when what it holds is not one. */
	function decode(reader:JsonWireReader):T;
}
