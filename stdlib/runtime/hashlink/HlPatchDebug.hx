package runtime.hashlink;

import runtime.memory.RawPtr;

/** C-layout source span corresponding to one encoded HashLink opcode. */
@:value @:repr("C")
class HlSourceSpan {
	public var file:Int32;
	public var line:Int32;
	public var column:Int32;
	public var endLine:Int32;
	public var endColumn:Int32;
	public var sourceHash:Int32;
	public var start:Int32;
	public var end:Int32;
	public var flags:Int32;
}

/** C-layout source snapshot retained by a patch debug region. */
@:value @:repr("C")
class HlSourceSnapshot {
	public var sourceHash:Int32;
	public var length:Int32;
	public var content:RawPtr<UInt8>;
}

/** Haxe-arena-owned debug metadata consumed by one native patch allocation. */
@:value @:repr("C")
class HlRuntimePatchDebug {
	public var functionCount:Int32;
	public var spans:RawPtr<RawPtr<HlSourceSpan>>;
	public var snapshotCount:Int32;
	public var snapshots:RawPtr<HlSourceSnapshot>;
}
