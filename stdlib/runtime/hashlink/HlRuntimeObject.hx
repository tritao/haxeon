package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.hashlink.HlType;

/** C-layout equivalent of HashLink's runtime object metadata. */
@:value @:repr("C")
class HlRuntimeObject {
	public var type:RawPtr<HlType>;
	public var nfields:Int32;
	public var nproto:Int32;
	public var size:Int32;
	public var nmethods:Int32;
	public var nbindings:Int32;
	public var padSize:UInt8;
	public var largestField:UInt8;
	public var hasPtr:Bool;
	public var methods:RawPtr<RawPtr<UInt8>>;
	public var fieldIndexes:RawPtr<Int32>;
	public var bindings:RawPtr<HlRuntimeBinding>;
	public var parent:RawPtr<HlRuntimeObject>;
	public var toStringFun:RawPtr<UInt8>;
	public var compareFun:RawPtr<UInt8>;
	public var castFun:RawPtr<UInt8>;
	public var getFieldFun:RawPtr<UInt8>;
	public var nlookup:Int32;
	public var ninterfaces:Int32;
}

/** C-layout equivalent of HashLink's runtime binding metadata. */
@:value @:repr("C")
class HlRuntimeBinding {
	public var pointer:RawPtr<UInt8>;
	public var closure:RawPtr<HlType>;
	public var functionId:Int32;
}
