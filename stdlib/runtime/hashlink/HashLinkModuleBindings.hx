package runtime.hashlink;

/**
	Canonical aliases for the native records imported from
	HashLinkModuleMetadata.hxi.

	Module descriptors use the same canonical records as the runtime loader. The
	aliases keep generated HXI bindings and source-declared metadata on one
	RawPtr and layout model without adding a parallel descriptor representation.
*/
typedef NativeModuleHlAlloc = runtime.hashlink.HlModuleContext.HlAllocation;
typedef NativeModuleHlCode = runtime.hashlink.HlNativeCode;
typedef NativeModuleHlConstant = runtime.hashlink.HlConstant;
typedef NativeModuleHlDebugSection = runtime.hashlink.HlDebugSection;
typedef NativeModuleHlFunction = runtime.hashlink.HlFunction;
typedef NativeModuleHlFunctionField = runtime.hashlink.HlFunction.HlFunctionField;
typedef NativeModuleHlNative = runtime.hashlink.HlNative;
typedef NativeModuleHlOpcode = runtime.hashlink.HlOpcode;
typedef NativeModuleHlPatchDebug = runtime.hashlink.HlPatchDebug.HlRuntimePatchDebug;
typedef NativeModuleHlPatchFunction = runtime.hashlink.HlPatchInput.HlRuntimePatchFunctionInput;
typedef NativeModuleHlPatchInput = runtime.hashlink.HlPatchInput.HlRuntimePatchInput;
typedef NativeModuleHlPatchInstruction = runtime.hashlink.HlPatchInput.HlRuntimePatchInstruction;
typedef NativeModuleHlPatchPools = runtime.hashlink.HlPatchPools;
typedef NativeModuleHlSourceSnapshot = runtime.hashlink.HlPatchDebug.HlSourceSnapshot;
typedef NativeModuleHlSourceSpan = runtime.hashlink.HlPatchDebug.HlSourceSpan;
typedef NativeModuleHlType = runtime.hashlink.HashLinkTypeBindings.NativeHlType;
typedef NativeModuleHlTypeObj = runtime.hashlink.HashLinkTypeBindings.NativeHlTypeObj;
