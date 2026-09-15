package runtime.hashlink;

import runtime.memory.RawPtr;

typedef HlObjectFieldSpec = {
	final name:RawPtr<UInt16>;
	final type:RawPtr<HlType>;
	final hashedName:Int;
}

typedef HlObjectProtoSpec = {
	final name:RawPtr<UInt16>;
	final findex:Int;
	final pindex:Int;
	final hashedName:Int;
}

typedef HlEnumConstructSpec = {
	final name:RawPtr<UInt16>;
	final parameters:Array<RawPtr<HlType>>;
	final size:Int;
	final hasPtr:Bool;
	final offsets:Array<Int>;
}

/** Builds HashLink type graphs in stable storage without exposing allocation policy. */
class HlTypeBuilder {
	public final arena:HlTypeArena;

	public function new(arena:HlTypeArena)
		this.arena = arena;

	public function primitive(kind:HlTypeKind):RawPtr<HlType> {
		var type = allocateType(kind);
		return type;
	}

	/** Copy a Haxe string into arena-owned, null-terminated UTF-16 storage. */
	public function utf16Name(value:String):RawPtr<UInt16> {
		var result = arena.allocUtf16Array(value.length + 1);
		for (index in 0...value.length)
			result.offset(index).store(cast value.charCodeAt(index));
		result.offset(value.length).store(cast 0);
		return result;
	}

	public function typeParameter(parameter:RawPtr<HlType>):RawPtr<HlType> {
		var type = allocateType(HlTypeKind.Reference);
		type.ref.data.ref.typeParam = parameter;
		return type;
	}

	public function functionType(arguments:Array<RawPtr<HlType>>, returnType:RawPtr<HlType>):RawPtr<HlType> {
		var nargs = arguments.length;
		var functionData = arena.allocTypeFunction();
		var nativeArguments:RawPtr<RawPtr<HlType>>;
		if (nargs == 0)
			nativeArguments = RawPtr.nullPtr();
		else {
			nativeArguments = arena.allocTypePointerArray(nargs);
			for (index in 0...nargs)
				nativeArguments.offset(index).store(arguments[index]);
		}
		functionData.ref.args = nativeArguments;
		functionData.ref.ret = returnType;
		functionData.ref.nargs = cast nargs;
		functionData.ref.parent = RawPtr.nullPtr();
		functionData.ref.closureType.ref.kind = cast HlTypeKind.VoidType;
		functionData.ref.closureType.ref.pointer = RawPtr.nullPtr();
		functionData.ref.closure.ref.args = nativeArguments;
		functionData.ref.closure.ref.ret = returnType;
		functionData.ref.closure.ref.nargs = cast nargs;
		functionData.ref.closure.ref.parent = RawPtr.nullPtr();
		var type = allocateType(HlTypeKind.Function);
		type.ref.data.ref.fun = functionData;
		return type;
	}

	public function objectType(name:RawPtr<UInt16>, superType:RawPtr<HlType>, fields:Array<HlObjectFieldSpec>, prototypes:Array<HlObjectProtoSpec>,
			bindings:Array<Int>, globalValue:RawPtr<RawPtr<UInt8>>, module:RawPtr<HlModuleContext>, runtime:RawPtr<HlRuntimeObject>):RawPtr<HlType> {
		var objectData = arena.allocTypeObject();
		objectData.ref.nfields = cast fields.length;
		objectData.ref.nproto = cast prototypes.length;
		objectData.ref.nbindings = cast bindings.length;
		objectData.ref.name = name;
		objectData.ref.superType = superType;
		objectData.ref.fields = objectFields(fields);
		objectData.ref.proto = objectPrototypes(prototypes);
		objectData.ref.bindings = int32Values(bindings);
		objectData.ref.globalValue = globalValue;
		objectData.ref.module = module;
		objectData.ref.runtime = runtime;
		var type = allocateType(HlTypeKind.Object);
		type.ref.data.ref.obj = objectData;
		return type;
	}

	public function moduleContext(functions:Array<RawPtr<UInt8>>, types:Array<RawPtr<HlType>>):RawPtr<HlModuleContext> {
		if (functions.length != types.length)
			throw "HashLink module function and type tables must have equal lengths";
		var context = arena.allocModuleContext(),
			nativeFunctions:RawPtr<RawPtr<UInt8>> = functions.length == 0 ? RawPtr.nullPtr() : arena.allocNativePointerArray(functions.length),
			nativeTypes:RawPtr<RawPtr<HlType>> = types.length == 0 ? RawPtr.nullPtr() : arena.allocTypePointerArray(types.length);
		context.ref.alloc.ref.current = RawPtr.nullPtr();
		if (functions.length != 0)
			for (index in 0...functions.length) {
				nativeFunctions.offset(index).store(functions[index]);
				nativeTypes.offset(index).store(types[index]);
			}
		context.ref.functionsPtrs = nativeFunctions;
		context.ref.functionsTypes = nativeTypes;
		arena.ownModuleContext(context);
		return context;
	}

	public function enumType(name:RawPtr<UInt16>, constructs:Array<HlEnumConstructSpec>, globalValue:RawPtr<RawPtr<UInt8>>):RawPtr<HlType> {
		var enumData = arena.allocTypeEnum(),
			nativeConstructs:RawPtr<HlEnumConstruct>;
		enumData.ref.name = name;
		enumData.ref.nconstructs = cast constructs.length;
		enumData.ref.globalValue = globalValue;
		if (constructs.length == 0)
			nativeConstructs = RawPtr.nullPtr();
		else {
			nativeConstructs = arena.allocEnumConstructArray(constructs.length);
			for (index in 0...constructs.length) {
				var source = constructs[index], destination = nativeConstructs.offset(index),
					parameters:RawPtr<RawPtr<HlType>> = source.parameters.length == 0 ? RawPtr.nullPtr() : arena.allocTypePointerArray(source.parameters.length),
					offsets:RawPtr<Int32> = source.offsets.length == 0 ? RawPtr.nullPtr() : arena.allocInt32Array(source.offsets.length);
				if (source.parameters.length != 0)
					for (parameterIndex in 0...source.parameters.length)
						parameters.offset(parameterIndex).store(source.parameters[parameterIndex]);
				if (source.offsets.length != 0)
					for (offsetIndex in 0...source.offsets.length)
						offsets.offset(offsetIndex).store(cast source.offsets[offsetIndex]);
				destination.ref.name = source.name;
				destination.ref.nparams = cast source.parameters.length;
				destination.ref.params = parameters;
				destination.ref.size = cast source.size;
				destination.ref.hasPtr = source.hasPtr;
				destination.ref.offsets = offsets;
			}
		}
		enumData.ref.constructs = nativeConstructs;
		var type = allocateType(HlTypeKind.Enum);
		type.ref.data.ref.enumType = enumData;
		return type;
	}

	public function virtualType(fields:Array<HlObjectFieldSpec>, dataSize:Int, indexes:Array<Int>, lookup:RawPtr<UInt8>):RawPtr<HlType> {
		var virtualData = arena.allocTypeVirtual();
		virtualData.ref.fields = objectFields(fields);
		virtualData.ref.nfields = cast fields.length;
		virtualData.ref.dataSize = cast dataSize;
		virtualData.ref.indexes = int32Values(indexes);
		virtualData.ref.lookup = lookup;
		var type = allocateType(HlTypeKind.Virtual);
		type.ref.data.ref.virtualType = virtualData;
		return type;
	}

	function objectFields(values:Array<HlObjectFieldSpec>):RawPtr<HlObjectField> {
		if (values.length == 0)
			return RawPtr.nullPtr();
		var result = arena.allocObjectFieldArray(values.length);
		for (index in 0...values.length) {
			var source = values[index], destination = result.offset(index);
			destination.ref.name = source.name;
			destination.ref.type = source.type;
			destination.ref.hashedName = cast source.hashedName;
		}
		return result;
	}

	function objectPrototypes(values:Array<HlObjectProtoSpec>):RawPtr<HlObjectProto> {
		if (values.length == 0)
			return RawPtr.nullPtr();
		var result = arena.allocObjectProtoArray(values.length);
		for (index in 0...values.length) {
			var source = values[index], destination = result.offset(index);
			destination.ref.name = source.name;
			destination.ref.findex = cast source.findex;
			destination.ref.pindex = cast source.pindex;
			destination.ref.hashedName = cast source.hashedName;
		}
		return result;
	}

	function int32Values(values:Array<Int>):RawPtr<Int32> {
		if (values.length == 0)
			return RawPtr.nullPtr();
		var result = arena.allocInt32Array(values.length);
		for (index in 0...values.length)
			result.offset(index).store(cast values[index]);
		return result;
	}

	function allocateType(kind:HlTypeKind):RawPtr<HlType> {
		var type = arena.allocType();
		type.ref.kind = cast kind;
		type.ref.data.ref.typeParam = RawPtr.nullPtr();
		type.ref.vobjProto = RawPtr.nullPtr();
		type.ref.markBits = RawPtr.nullPtr();
		type.ref.gcOwner = RawPtr.nullPtr();
		return type;
	}
}
