package runtime.hashlink;

import runtime.memory.RawPtr;

/** C-layout instruction projection for an already decoded HLP function. */
@:value @:repr("C")
class HlRuntimePatchInstruction {
	public var opcode:Int32;
	public var operandCount:Int32;
	public var operands:RawPtr<Int32>;
}

/** C-layout function projection for an already decoded HLP replacement. */
@:value @:repr("C")
class HlRuntimePatchFunctionInput {
	public var type:Int32;
	public var stableId:Int32;
	public var slot:Int32;
	public var registerCount:Int32;
	public var registers:RawPtr<Int32>;
	public var instructionCount:Int32;
	public var instructions:RawPtr<HlRuntimePatchInstruction>;
	public var relocationCount:Int32;
	public var relocationInstructions:RawPtr<Int32>;
	public var relocationStableIds:RawPtr<Int32>;
	public var debugCount:Int32;
	public var debugSpans:RawPtr<HlSourceSpan>;
}

/** Haxe-owned decoded HLP model projected into the native patch ABI. */
@:value @:repr("C")
class HlRuntimePatchInput {
	public var moduleId:RawPtr<UInt8>;
	public var baseRevision:Int32;
	public var revision:Int32;
	public var intPrefixHash:Int32;
	public var floatPrefixHash:Int32;
	public var stringPrefixHash:Int32;
	public var typePrefixHash:Int32;
	public var baseIntCount:Int32;
	public var intCount:Int32;
	public var ints:RawPtr<Int32>;
	public var floatCount:Int32;
	public var baseFloatCount:Int32;
	public var floats:RawPtr<Float>;
	public var stringCount:Int32;
	public var baseStringCount:Int32;
	public var strings:RawPtr<RawPtr<UInt8>>;
	public var stringLengths:RawPtr<Int32>;
	public var typeCount:Int32;
	public var baseTypeCount:Int32;
	public var functionCount:Int32;
	public var functions:RawPtr<HlRuntimePatchFunctionInput>;
	public var debugFileCount:Int32;
	public var debugFiles:RawPtr<RawPtr<UInt8>>;
	public var debugFileLengths:RawPtr<Int32>;
	public var sourceSnapshotCount:Int32;
	public var sourceSnapshots:RawPtr<HlSourceSnapshot>;
}
