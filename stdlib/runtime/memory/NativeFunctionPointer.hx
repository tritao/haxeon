package runtime.memory;

import runtime.memory.RawPtr;

/**
	A typed, non-owning native function-pointer slot.

	The phantom signature keeps unrelated callback slots distinct while the
	representation remains one unmanaged pointer. Indirect invocation is not
	part of this restricted runtime primitive yet.
*/
abstract NativeFunctionPointer<S>(hl.Bytes) from hl.Bytes to hl.Bytes {
	/** Reports whether this slot contains a null address. */
	public inline function isNull():Bool
		return (this : hl.Bytes) == null;

	/** Expose the address for a deliberately low-level native bridge. */
	public inline function raw():RawPtr<UInt8>
		return cast this;
}
