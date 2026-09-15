package runtime.hashlink;

import runtime.memory.RawPtr;

/** C-layout equivalent of HashLink's bytecode function descriptor. */
@:value @:repr("C")
class HlFunction {
	public var findex:Int32;
	public var nregs:Int32;
	public var nops:Int32;
	public var reference:Int32;
	public var nassigns:Int32;
	public var type:RawPtr<HlType>;
	public var regs:RawPtr<RawPtr<HlType>>;
	public var ops:RawPtr<UInt8>;
	public var debug:RawPtr<Int32>;
	public var assigns:RawPtr<Int32>;
	public var object:RawPtr<HlTypeObject>;
	public var field:HlFunctionField;
}

/** Named union holding an unbound field name or a field-function reference. */
@:value @:repr("C") @:union
class HlFunctionField {
	public var name:RawPtr<UInt16>;
	public var reference:RawPtr<HlFunction>;
}
