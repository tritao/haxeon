package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.hashlink.HlType;

/** C-layout equivalent of HashLink's hl_type_fun metadata. */
@:value @:repr("C")
class HlTypeFunction {
	public var args:RawPtr<RawPtr<HlType>>;
	public var ret:RawPtr<HlType>;
	public var nargs:Int32;
	public var parent:RawPtr<HlType>;
	public var closureType:HlTypeClosureType;
	public var closure:HlTypeClosure;
}

/** Nested closure_type aggregate in hl_type_fun. */
@:value @:repr("C")
class HlTypeClosureType {
	public var kind:Int32;
	public var pointer:RawPtr<UInt8>;
}

/** Nested closure aggregate in hl_type_fun. */
@:value @:repr("C")
class HlTypeClosure {
	public var args:RawPtr<RawPtr<HlType>>;
	public var ret:RawPtr<HlType>;
	public var nargs:Int32;
	public var parent:RawPtr<HlType>;
}
