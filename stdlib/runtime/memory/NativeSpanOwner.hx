package runtime.memory;

/** Something that owns native memory spans borrow. A span reads only while its owner is open. */
interface NativeSpanOwner {
	/** Whether the owner has released the memory, so its spans may no longer read it. */
	function isClosed():Bool;
}
