package runtime.hashlink;

import runtime.memory.RawPtr;

/** Haxe-resolved stable-ID and relocation slots for one HLP transaction. */
@:value @:repr("C")
class HlPatchFunctionResolution {
	public var stableId:Int32;
	public var slot:Int32;
	public var relocationCount:Int32;
	public var relocationStableIds:RawPtr<Int32>;
	public var relocationSlots:RawPtr<Int32>;
}

/** Arena-owned resolution plan handed to the native patch validator. */
@:value @:repr("C")
class HlRuntimePatchResolution {
	public var functionCount:Int32;
	public var functions:RawPtr<HlPatchFunctionResolution>;
}
