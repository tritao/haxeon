package haxeon.wire;

/**
	The contract emitted by a typed MessagePack codec generator.

	Codecs operate directly on format primitives. They do not need reflection,
	Dynamic intermediate values, or a runtime type registry.
 */
interface MessagePackCodec<T> {
	function encode(writer:MessagePackWriter, value:T):Void;
	function decode(reader:MessagePackReader):T;
}
