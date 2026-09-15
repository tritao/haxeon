package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.hashlink.HlType;
import runtime.hashlink.HlTypeFunction;
import runtime.hashlink.HlTypeObject;
import runtime.hashlink.HlTypeObject.HlTypeEnum;
import runtime.hashlink.HlTypeObject.HlTypeVirtual;

/** Anonymous union in HashLink's hl_type declaration. */
@:value @:repr("C") @:union
class HlTypeData {
	public var absName:RawPtr<UInt16>;
	public var fun:RawPtr<HlTypeFunction>;
	public var obj:RawPtr<HlTypeObject>;
	public var enumType:RawPtr<HlTypeEnum>;
	public var virtualType:RawPtr<HlTypeVirtual>;
	public var typeParam:RawPtr<HlType>;
}
