package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.hashlink.HlTypeData;

/** C-layout equivalent of HashLink's hl_type header. */
@:value @:repr("C")
class HlType {
	public var kind:Int32;
	public var data:HlTypeData;
	public var vobjProto:RawPtr<RawPtr<UInt8>>;
	public var markBits:RawPtr<UInt32>;
	public var gcOwner:RawPtr<UInt8>;
}
