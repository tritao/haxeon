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

typedef HlObjectBindingSpec = {
	final fieldIndex:Int;
	final functionIndex:Int;
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

	/** Copy a Haxe string into arena-owned, null-terminated UTF-8 storage. */
	public function utf8Name(value:String):RawPtr<UInt8> {
		var bytes = utf8Bytes(value), result = arena.allocUInt8Array(bytes.length + 1);
		for (index in 0...bytes.length)
			result.offset(index).store(cast bytes[index]);
		result.offset(bytes.length).store(cast 0);
		return result;
	}

	/** Hash a HashLink UTF-16 field name using the VM's stable name hash. */
	public static function hashUtf16(value:String):Int {
		var hash = 0;
		for (index in 0...value.length)
			hash = 223 * hash + value.charCodeAt(index);
		return hash % 0x1FFFFF7B;
	}

	public function typeParameter(parameter:RawPtr<HlType>):RawPtr<HlType> {
		return parameterizedType(HlTypeKind.Reference, parameter);
	}

	/** Allocate any of HashLink's parameterized type forms. */
	public function parameterizedType(kind:HlTypeKind, parameter:RawPtr<HlType>):RawPtr<HlType> {
		if (kind != HlTypeKind.Reference && kind != HlTypeKind.Nullable && kind != HlTypeKind.Packed)
			throw "HashLink parameterized types must be references, nullable values, or packed values";
		var type = allocateType(kind);
		type.ref.data.ref.typeParam = parameter;
		return type;
	}

	/** Allocate a function type header before its signature is known. */
	public function functionTypeSkeleton(?kind:HlTypeKind = HlTypeKind.Function):RawPtr<HlType> {
		if (kind != HlTypeKind.Function && kind != HlTypeKind.Method)
			throw "HashLink function type skeletons must be functions or methods";
		var type = allocateType(kind), functionData = arena.allocTypeFunction();
		functionData.ref.args = RawPtr.nullPtr();
		functionData.ref.ret = RawPtr.nullPtr();
		functionData.ref.nargs = 0;
		functionData.ref.parent = RawPtr.nullPtr();
		functionData.ref.closureType.ref.kind = cast HlTypeKind.VoidType;
		functionData.ref.closureType.ref.pointer = RawPtr.nullPtr();
		functionData.ref.closure.ref.args = RawPtr.nullPtr();
		functionData.ref.closure.ref.ret = RawPtr.nullPtr();
		functionData.ref.closure.ref.nargs = 0;
		functionData.ref.closure.ref.parent = RawPtr.nullPtr();
		type.ref.data.ref.fun = functionData;
		return type;
	}

	/** Complete a function type skeleton after all recursive signature types are available. */
	public function defineFunctionType(type:RawPtr<HlType>, arguments:Array<RawPtr<HlType>>, returnType:RawPtr<HlType>):Void {
		var kind:HlTypeKind = cast type.ref.kind;
		if (kind != HlTypeKind.Function && kind != HlTypeKind.Method)
			throw "HashLink function definition requires a function type skeleton";
		var nargs = arguments.length, functionData = type.ref.data.ref.fun,
			nativeArguments:RawPtr<RawPtr<HlType>>;
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
		// HashLink derives the closure view lazily in hl_get_closure_type().
		// Keep this cache zeroed so native closure allocation remains authoritative.
		functionData.ref.closureType.ref.kind = cast HlTypeKind.VoidType;
		functionData.ref.closureType.ref.pointer = RawPtr.nullPtr();
		functionData.ref.closure.ref.args = RawPtr.nullPtr();
		functionData.ref.closure.ref.ret = RawPtr.nullPtr();
		functionData.ref.closure.ref.nargs = 0;
		functionData.ref.closure.ref.parent = RawPtr.nullPtr();
	}

	public function functionType(arguments:Array<RawPtr<HlType>>, returnType:RawPtr<HlType>):RawPtr<HlType> {
		var type = functionTypeSkeleton();
		defineFunctionType(type, arguments, returnType);
		return type;
	}

	/** Construct an abstract type with its arena-owned name. */
	public function abstractType(name:RawPtr<UInt16>):RawPtr<HlType> {
		var type = allocateType(HlTypeKind.Abstract);
		type.ref.data.ref.absName = name;
		return type;
	}

	/** Allocate an object type header before its fields are known. */
	public function objectTypeSkeleton(?kind:HlTypeKind = HlTypeKind.Object):RawPtr<HlType> {
		if (kind != HlTypeKind.Object && kind != HlTypeKind.Struct)
			throw "HashLink object type skeletons must be objects or structures";
		var type = allocateType(kind), objectData = arena.allocTypeObject();
		objectData.ref.nfields = 0;
		objectData.ref.nproto = 0;
		objectData.ref.nbindings = 0;
		objectData.ref.name = RawPtr.nullPtr();
		objectData.ref.superType = RawPtr.nullPtr();
		objectData.ref.fields = RawPtr.nullPtr();
		objectData.ref.proto = RawPtr.nullPtr();
		objectData.ref.bindings = RawPtr.nullPtr();
		objectData.ref.globalValue = RawPtr.nullPtr();
		objectData.ref.module = RawPtr.nullPtr();
		objectData.ref.runtime = RawPtr.nullPtr();
		type.ref.data.ref.obj = objectData;
		return type;
	}

	/** Complete an object type skeleton after all recursive pointees are available. */
	public function defineObjectType(type:RawPtr<HlType>, name:RawPtr<UInt16>, superType:RawPtr<HlType>, fields:Array<HlObjectFieldSpec>,
			prototypes:Array<HlObjectProtoSpec>, bindings:Array<HlObjectBindingSpec>, globalValue:RawPtr<RawPtr<UInt8>>,
			module:RawPtr<HlModuleContext>, runtime:RawPtr<HlRuntimeObject>):Void {
		var kind:HlTypeKind = cast type.ref.kind;
		if (kind != HlTypeKind.Object && kind != HlTypeKind.Struct)
			throw "HashLink object definition requires an object type skeleton";
		var objectData = type.ref.data.ref.obj;
		objectData.ref.nfields = cast fields.length;
		objectData.ref.nproto = cast prototypes.length;
		objectData.ref.nbindings = cast bindings.length;
		objectData.ref.name = name;
		objectData.ref.superType = superType;
		objectData.ref.fields = objectFields(fields);
		objectData.ref.proto = objectPrototypes(prototypes);
		objectData.ref.bindings = objectBindings(bindings);
		objectData.ref.globalValue = globalValue;
		objectData.ref.module = module;
		objectData.ref.runtime = runtime;
	}

	public function objectType(name:RawPtr<UInt16>, superType:RawPtr<HlType>, fields:Array<HlObjectFieldSpec>, prototypes:Array<HlObjectProtoSpec>,
			bindings:Array<HlObjectBindingSpec>, globalValue:RawPtr<RawPtr<UInt8>>, module:RawPtr<HlModuleContext>, runtime:RawPtr<HlRuntimeObject>):RawPtr<HlType> {
		var type = objectTypeSkeleton();
		defineObjectType(type, name, superType, fields, prototypes, bindings, globalValue, module, runtime);
		return type;
	}

	public function moduleContext(functions:Array<RawPtr<UInt8>>, types:Array<RawPtr<HlType>>):RawPtr<HlModuleContext> {
		return moduleContextFromTable(new HlFunctionTable(arena, functions, types));
	}

	/** Bind a Haxe-owned function table into a HashLink module context. */
	public function moduleContextFromTable(table:HlFunctionTable):RawPtr<HlModuleContext> {
		if (table.arena != arena)
			throw "HashLink function table and module context must share an arena";
		var context = arena.allocModuleContext(),
			nativeFunctions = table.functionPointer(),
			nativeTypes = table.typePointer();
		context.ref.alloc.ref.current = RawPtr.nullPtr();
		context.ref.functionsPtrs = nativeFunctions;
		context.ref.functionsTypes = nativeTypes;
		arena.ownModuleContext(context);
		return context;
	}

	/** Allocate an enum type header before its constructors are known. */
	public function enumTypeSkeleton():RawPtr<HlType> {
		var type = allocateType(HlTypeKind.Enum), enumData = arena.allocTypeEnum();
		enumData.ref.name = RawPtr.nullPtr();
		enumData.ref.nconstructs = 0;
		enumData.ref.constructs = RawPtr.nullPtr();
		enumData.ref.globalValue = RawPtr.nullPtr();
		type.ref.data.ref.enumType = enumData;
		return type;
	}

	/** Complete an enum type skeleton after all recursive constructor types are available. */
	public function defineEnumType(type:RawPtr<HlType>, name:RawPtr<UInt16>, constructs:Array<HlEnumConstructSpec>,
			globalValue:RawPtr<RawPtr<UInt8>>):Void {
		var kind:HlTypeKind = cast type.ref.kind;
		if (kind != HlTypeKind.Enum)
			throw "HashLink enum definition requires an enum type skeleton";
		var enumData = type.ref.data.ref.enumType;
		enumData.ref.name = name;
		enumData.ref.nconstructs = cast constructs.length;
		enumData.ref.globalValue = globalValue;
		enumData.ref.constructs = enumConstructs(constructs);
	}

	public function enumType(name:RawPtr<UInt16>, constructs:Array<HlEnumConstructSpec>, globalValue:RawPtr<RawPtr<UInt8>>):RawPtr<HlType> {
		var type = enumTypeSkeleton();
		defineEnumType(type, name, constructs, globalValue);
		return type;
	}

	/** Allocate a virtual type header before its fields are known. */
	public function virtualTypeSkeleton():RawPtr<HlType> {
		var type = allocateType(HlTypeKind.Virtual), virtualData = arena.allocTypeVirtual();
		virtualData.ref.fields = RawPtr.nullPtr();
		virtualData.ref.nfields = 0;
		virtualData.ref.dataSize = 0;
		virtualData.ref.indexes = RawPtr.nullPtr();
		virtualData.ref.lookup = RawPtr.nullPtr();
		type.ref.data.ref.virtualType = virtualData;
		return type;
	}

	/** Complete a virtual type skeleton after all recursive field types are available. */
	public function defineVirtualType(type:RawPtr<HlType>, fields:Array<HlObjectFieldSpec>, dataSize:Int, indexes:Array<Int>,
			lookup:RawPtr<HlFieldLookup>):Void {
		var kind:HlTypeKind = cast type.ref.kind;
		if (kind != HlTypeKind.Virtual)
			throw "HashLink virtual definition requires a virtual type skeleton";
		var virtualData = type.ref.data.ref.virtualType;
		virtualData.ref.fields = objectFields(fields);
		virtualData.ref.nfields = cast fields.length;
		virtualData.ref.dataSize = cast dataSize;
		virtualData.ref.indexes = int32Values(indexes);
		virtualData.ref.lookup = lookup;
	}

	public function virtualType(fields:Array<HlObjectFieldSpec>, dataSize:Int, indexes:Array<Int>, lookup:RawPtr<HlFieldLookup>):RawPtr<HlType> {
		var type = virtualTypeSkeleton();
		defineVirtualType(type, fields, dataSize, indexes, lookup);
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

	function objectBindings(values:Array<HlObjectBindingSpec>):RawPtr<Int32> {
		if (values.length == 0)
			return RawPtr.nullPtr();
		var result = arena.allocInt32Array(values.length * 2);
		for (index in 0...values.length) {
			var source = values[index];
			result.offset(index * 2).store(cast source.fieldIndex);
			result.offset(index * 2 + 1).store(cast source.functionIndex);
		}
		return result;
	}

	function enumConstructs(values:Array<HlEnumConstructSpec>):RawPtr<HlEnumConstruct> {
		if (values.length == 0)
			return RawPtr.nullPtr();
		var result = arena.allocEnumConstructArray(values.length);
		for (index in 0...values.length) {
			var source = values[index], destination = result.offset(index),
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

	static function utf8Bytes(value:String):Array<Int> {
		var result:Array<Int> = [], index = 0;
		while (index < value.length) {
			var code = value.charCodeAt(index++);
			if (code >= 0xD800 && code <= 0xDBFF && index < value.length) {
				var low = value.charCodeAt(index);
				if (low >= 0xDC00 && low <= 0xDFFF) {
					code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
					index++;
				}
			}
			if (code <= 0x7F)
				result.push(code);
			else if (code <= 0x7FF) {
				result.push(0xC0 | (code >> 6));
				result.push(0x80 | (code & 0x3F));
			} else if (code <= 0xFFFF) {
				result.push(0xE0 | (code >> 12));
				result.push(0x80 | ((code >> 6) & 0x3F));
				result.push(0x80 | (code & 0x3F));
			} else {
				result.push(0xF0 | (code >> 18));
				result.push(0x80 | ((code >> 12) & 0x3F));
				result.push(0x80 | ((code >> 6) & 0x3F));
				result.push(0x80 | (code & 0x3F));
			}
		}
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
