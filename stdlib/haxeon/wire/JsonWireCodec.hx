package haxeon.wire;

/** Contract for an explicit JSON codec. */
interface JsonWireCodec<T> {
	function encode(writer:JsonWireWriter, value:T):Void;
	function decode(reader:JsonWireReader):T;
}
