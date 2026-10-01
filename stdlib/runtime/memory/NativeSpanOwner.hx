package runtime.memory;

/** Something that owns native memory spans borrow. A span reads only while its owner is open. */
interface NativeSpanOwner {
	function isClosed():Bool;
}
