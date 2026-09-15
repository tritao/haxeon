package runtime.hashlink;

import runtime.memory.RawPtr;

/** C-layout equivalent of HashLink's native function binding descriptor. */
@:value @:repr("C")
class HlNative {
	public var library:RawPtr<UInt8>;
	public var name:RawPtr<UInt8>;
	public var type:RawPtr<HlType>;
	public var findex:Int32;
}
