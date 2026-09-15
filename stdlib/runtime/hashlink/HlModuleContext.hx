package runtime.hashlink;

import runtime.memory.RawPtr;

/** C-layout equivalent of HashLink's small allocation context used by modules. */
@:value @:repr("C")
class HlModuleContext {
	public var alloc:HlAllocation;
	public var functionsPtrs:RawPtr<RawPtr<UInt8>>;
	public var functionsTypes:RawPtr<RawPtr<HlType>>;
}

/** C-layout equivalent of HashLink's hl_alloc wrapper. */
@:value @:repr("C")
class HlAllocation {
	public var current:RawPtr<UInt8>;
}
