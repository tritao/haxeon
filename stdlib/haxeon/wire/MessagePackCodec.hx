package haxeon.wire;

/**
	The contract emitted by a typed MessagePack codec generator.

	Codecs operate directly on format primitives. They do not need reflection,
	Dynamic intermediate values, or a runtime type registry.
 */
interface MessagePackCodec<T> {
	/** Writes `value` to `writer`. */
	function encode(writer:MessagePackWriter, value:T):Void;

	/** Reads a value from `reader`; throws a `MessagePackError` when what it holds is not one. */
	function decode(reader:MessagePackReader):T;
}
