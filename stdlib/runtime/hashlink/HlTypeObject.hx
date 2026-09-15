package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.hashlink.HlType;
import runtime.hashlink.HlModuleContext;
import runtime.hashlink.HlRuntimeObject;

/** C-layout equivalent of HashLink's hl_type_obj metadata. */
@:value @:repr("C")
class HlTypeObject {
	public var nfields:Int32;
	public var nproto:Int32;
	public var nbindings:Int32;
	public var name:RawPtr<UInt16>;
	public var superType:RawPtr<HlType>;
	public var fields:RawPtr<HlObjectField>;
	public var proto:RawPtr<HlObjectProto>;
	public var bindings:RawPtr<Int32>;
	public var globalValue:RawPtr<RawPtr<UInt8>>;
	public var module:RawPtr<HlModuleContext>;
	public var runtime:RawPtr<HlRuntimeObject>;
}

/** C-layout equivalent of HashLink's hl_obj_field metadata. */
@:value @:repr("C")
class HlObjectField {
	public var name:RawPtr<UInt16>;
	public var type:RawPtr<HlType>;
	public var hashedName:Int32;
}

/** C-layout equivalent of HashLink's hl_obj_proto metadata. */
@:value @:repr("C")
class HlObjectProto {
	public var name:RawPtr<UInt16>;
	public var findex:Int32;
	public var pindex:Int32;
	public var hashedName:Int32;
}

/** C-layout equivalent of HashLink's hl_type_virtual metadata. */
@:value @:repr("C")
class HlTypeVirtual {
	public var fields:RawPtr<HlObjectField>;
	public var nfields:Int32;
	public var dataSize:Int32;
	public var indexes:RawPtr<Int32>;
	public var lookup:RawPtr<UInt8>;
}

/** C-layout equivalent of HashLink's hl_type_enum metadata. */
@:value @:repr("C")
class HlTypeEnum {
	public var name:RawPtr<UInt16>;
	public var nconstructs:Int32;
	public var constructs:RawPtr<HlEnumConstruct>;
	public var globalValue:RawPtr<RawPtr<UInt8>>;
}

/** C-layout equivalent of HashLink's hl_enum_construct metadata. */
@:value @:repr("C")
class HlEnumConstruct {
	public var name:RawPtr<UInt16>;
	public var nparams:Int32;
	public var params:RawPtr<RawPtr<HlType>>;
	public var size:Int32;
	public var hasPtr:Bool;
	public var offsets:RawPtr<Int32>;
}
