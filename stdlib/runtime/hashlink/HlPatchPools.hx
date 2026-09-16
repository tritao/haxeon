package runtime.hashlink;

import runtime.memory.RawPtr;

/** C-layout view of the cumulative scalar pools for one Haxe-owned patch. */
@:value @:repr("C")
class HlPatchPools {
	public var intCount:Int32;
	public var floatCount:Int32;
	public var stringCount:Int32;
	public var ints:RawPtr<Int32>;
	public var floats:RawPtr<Float>;
	public var strings:RawPtr<RawPtr<UInt8>>;
	public var stringLengths:RawPtr<Int32>;
	public var ustrings:RawPtr<RawPtr<UInt16>>;
}
