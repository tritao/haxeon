package runtime.hashlink;

import runtime.memory.RawPtr;

/** C-layout view of one complete Haxe-owned HashLink module record. */
@:value @:repr("C")
class HlNativeCode {
	public var version:Int32;
	public var intCount:Int32;
	public var floatCount:Int32;
	public var stringCount:Int32;
	public var bytePositionCount:Int32;
	public var typeCount:Int32;
	public var typeCapacity:Int32;
	public var globalCount:Int32;
	public var nativeCount:Int32;
	public var functionCount:Int32;
	public var constantCount:Int32;
	public var debugSectionCount:Int32;
	public var entryPoint:Int32;
	public var debugFileCount:Int32;
	public var hasDebug:Bool;
	public var ints:RawPtr<Int32>;
	public var floats:RawPtr<Float>;
	public var strings:RawPtr<RawPtr<UInt8>>;
	public var stringLengths:RawPtr<Int32>;
	public var bytes:RawPtr<UInt8>;
	public var bytePositions:RawPtr<Int32>;
	public var debugFiles:RawPtr<RawPtr<UInt8>>;
	public var debugFileLengths:RawPtr<Int32>;
	public var ustrings:RawPtr<RawPtr<UInt16>>;
	public var types:RawPtr<HlType>;
	public var globals:RawPtr<RawPtr<HlType>>;
	public var natives:RawPtr<HlNative>;
	public var functions:RawPtr<HlFunction>;
	public var functionStableIds:RawPtr<Int32>;
	public var functionNames:RawPtr<RawPtr<UInt8>>;
	public var functionNameLengths:RawPtr<Int32>;
	public var constants:RawPtr<HlConstant>;
	public var debugSections:RawPtr<HlDebugSection>;
	public var alloc:HlAllocation;
	public var falloc:HlAllocation;
}
