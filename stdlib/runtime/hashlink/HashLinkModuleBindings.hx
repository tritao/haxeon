package runtime.hashlink;

/**
	Canonical aliases for the native records imported from
	HashLinkModuleMetadata.hxi.

	Module descriptors use the same canonical records as the runtime loader. The
	aliases keep generated HXI bindings and source-declared metadata on one
	RawPtr and layout model without adding a parallel descriptor representation.
*/
typedef NativeModuleHlAlloc = HlAllocation;
typedef NativeModuleHlCode = HlNativeCode;
typedef NativeModuleHlConstant = HlConstant;
typedef NativeModuleHlDebugSection = HlDebugSection;
typedef NativeModuleHlFunction = HlFunction;
typedef NativeModuleHlFunctionField = HlFunctionField;
typedef NativeModuleHlNative = HlNative;
typedef NativeModuleHlOpcode = HlOpcode;
typedef NativeModuleHlPatchDebug = HlRuntimePatchDebug;
typedef NativeModuleHlPatchFunction = HlRuntimePatchFunctionInput;
typedef NativeModuleHlPatchInput = HlRuntimePatchInput;
typedef NativeModuleHlPatchInstruction = HlRuntimePatchInstruction;
typedef NativeModuleHlPatchPools = HlPatchPools;
typedef NativeModuleHlSourceSnapshot = HlSourceSnapshot;
typedef NativeModuleHlSourceSpan = HlSourceSpan;
typedef NativeModuleHlType = HashLinkTypeBindings.NativeHlType;
typedef NativeModuleHlTypeObj = HashLinkTypeBindings.NativeHlTypeObj;
