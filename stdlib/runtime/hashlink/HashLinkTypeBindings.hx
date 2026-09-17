package runtime.hashlink;

/**
	Canonical aliases for the native records imported from HashLinkMetadata.hxi.

	The HXI importer uses these names for generated native-record bindings. They
	remain aliases rather than new declarations, so imported HashLink pointers
	and the runtime-owned records share one layout and RawPtr representation.
*/
typedef NativeHlAlloc = HlAllocation;
typedef NativeHlEnumConstruct = HlEnumConstruct;
typedef NativeHlFieldLookup = HlFieldLookup;
typedef NativeHlModuleContext = HlModuleContext;
typedef NativeHlObjectField = HlObjectField;
typedef NativeHlObjectProto = HlObjectProto;
typedef NativeHlRuntimeBinding = HlRuntimeBinding;
typedef NativeHlRuntimeObj = HlRuntimeObject;
typedef NativeHlType = HlType;
typedef NativeHlTypeEnum = HlTypeEnum;
typedef NativeHlTypeFun = HlTypeFunction;
typedef NativeHlTypeFunClosure = HlTypeClosure;
typedef NativeHlTypeFunClosureType = HlTypeClosureType;
typedef NativeHlTypeObj = HlTypeObject;
typedef NativeHlTypeVirtual = HlTypeVirtual;
typedef NativeVvirtual = HlVirtualValue;
