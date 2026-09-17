package runtime.hashlink;

/**
	Canonical aliases for the native records imported from HashLinkMetadata.hxi.

	The HXI importer uses these names for generated native-record bindings. They
	remain aliases rather than new declarations, so imported HashLink pointers
	and the runtime-owned records share one layout and RawPtr representation.
*/
typedef NativeHlAlloc = runtime.hashlink.HlModuleContext.HlAllocation;
typedef NativeHlEnumConstruct = runtime.hashlink.HlTypeObject.HlEnumConstruct;
typedef NativeHlFieldLookup = runtime.hashlink.HlRuntimeObject.HlFieldLookup;
typedef NativeHlModuleContext = runtime.hashlink.HlModuleContext;
typedef NativeHlObjectField = runtime.hashlink.HlTypeObject.HlObjectField;
typedef NativeHlObjectProto = runtime.hashlink.HlTypeObject.HlObjectProto;
typedef NativeHlRuntimeBinding = runtime.hashlink.HlRuntimeObject.HlRuntimeBinding;
typedef NativeHlRuntimeObj = runtime.hashlink.HlRuntimeObject;
typedef NativeHlType = runtime.hashlink.HlType;
typedef NativeHlTypeEnum = runtime.hashlink.HlTypeObject.HlTypeEnum;
typedef NativeHlTypeFun = runtime.hashlink.HlTypeFunction;
typedef NativeHlTypeFunClosure = runtime.hashlink.HlTypeFunction.HlTypeClosure;
typedef NativeHlTypeFunClosureType = runtime.hashlink.HlTypeFunction.HlTypeClosureType;
typedef NativeHlTypeObj = runtime.hashlink.HlTypeObject;
typedef NativeHlTypeVirtual = runtime.hashlink.HlTypeObject.HlTypeVirtual;
typedef NativeVvirtual = runtime.hashlink.HlRuntimeObject.HlVirtualValue;
