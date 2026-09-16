package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.memory.NativeFunctionPointer;
import runtime.hashlink.HlType;

typedef HlToStringFunction = (object:RawPtr<UInt8>)->RawPtr<UInt8>;
typedef HlCompareFunction = (left:RawPtr<UInt8>, right:RawPtr<UInt8>)->Int32;
typedef HlCastFunction = (object:RawPtr<UInt8>, type:RawPtr<HlType>)->RawPtr<UInt8>;
typedef HlGetFieldFunction = (object:RawPtr<UInt8>, fieldHash:Int32)->RawPtr<UInt8>;

/** C-layout equivalent of HashLink's sorted field-lookup entry. */
@:value @:repr("C")
class HlFieldLookup {
	public var type:RawPtr<HlType>;
	public var hashedName:Int32;
	public var fieldIndex:Int32;
}

/** C-layout equivalent of the header preceding a virtual value's fields. */
@:value @:repr("C")
class HlVirtualValue {
	public var type:RawPtr<HlType>;
	public var value:RawPtr<UInt8>;
	public var next:RawPtr<HlVirtualValue>;
}

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
	public var toStringFun:NativeFunctionPointer<HlToStringFunction>;
	public var compareFun:NativeFunctionPointer<HlCompareFunction>;
	public var castFun:NativeFunctionPointer<HlCastFunction>;
	public var getFieldFun:NativeFunctionPointer<HlGetFieldFunction>;
	public var nlookup:Int32;
	public var ninterfaces:Int32;
	public var lookup:RawPtr<HlFieldLookup>;
	public var interfaces:RawPtr<Int32>;
}

/** C-layout equivalent of HashLink's runtime binding metadata. */
@:value @:repr("C")
class HlRuntimeBinding {
	public var pointer:RawPtr<UInt8>;
	public var closure:RawPtr<HlType>;
	public var fieldId:Int32;
}
