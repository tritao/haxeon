package runtime.hashlink;

import runtime.memory.RawPtr;

/** C-layout equivalent of HashLink's decoded bytecode instruction. */
@:value @:repr("C")
class HlOpcode {
	public var op:Int32;
	public var p1:Int32;
	public var p2:Int32;
	public var p3:Int32;
	public var extra:RawPtr<Int32>;
}
