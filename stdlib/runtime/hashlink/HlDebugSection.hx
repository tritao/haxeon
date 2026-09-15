package runtime.hashlink;

import haxe.io.Bytes;
import runtime.memory.RawPtr;

/** C-layout equivalent of HashLink's module-level debug-section record. */
@:value @:repr("C")
class HlDebugSection {
	public var kind:Int32;
	public var version:Int32;
	public var flags:Int32;
	public var size:Int32;
	public var data:RawPtr<UInt8>;
}

/** Input used to construct one Haxe-owned HashLink debug section. */
typedef HlDebugSectionSpec = {
	final kind:Int;
	final version:Int;
	final flags:Int;
	final payload:Bytes;
}
