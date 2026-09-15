package runtime.hashlink;

import runtime.memory.RawPtr;

/** C-layout equivalent of HashLink's global constant descriptor. */
@:value @:repr("C")
class HlConstant {
	public var global:Int32;
	public var nfields:Int32;
	public var fields:RawPtr<Int32>;
}
