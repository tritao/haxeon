import runtime.hashlink.HlTypeArena;
import runtime.hashlink.HlTypeBridge;
import runtime.hashlink.HlTypeBuilder;
import runtime.hashlink.HlTypeTable;
import runtime.hashlink.HlType;
import runtime.hashlink.HlTypeKind;
import runtime.hashlink.HlMetadataGeneration;
import runtime.memory.RawPtr;

function main():Int {
	var arena = new HlTypeArena(128),
		builder = new HlTypeBuilder(arena),
		type = arena.allocType(),
		functionType = arena.allocTypeFunction();
	type.ref.kind = 11;
	type.ref.data.ref.typeParam = type;
	var storedTypeParam = type.ref.data.ref.typeParam;
	functionType.ref.nargs = 2;
	type.ref.kind = 10;
	type.ref.data.ref.fun = functionType;
	var storedFunction = type.ref.data.ref.fun;
	var nativeKind = HlTypeBridge.native_type_kind(type),
		nativeSize = HlTypeBridge.native_type_size(type),
		nativeArity = HlTypeBridge.native_type_function_arity(type);
	var reused:RawPtr<HlType>;
	arena.reset();
	reused = arena.allocType();
	reused.ref.kind = 7;
	var correct = type.ref.kind == 7 && storedFunction == functionType && storedTypeParam == type && reused.ref.kind == 7 && nativeKind == 10
		&& nativeSize == 8 && nativeArity == 2;
	arena.reset();
	var voidType = builder.primitive(HlTypeKind.VoidType),
		intType = builder.primitive(HlTypeKind.Int32Type),
		builtFunction = builder.functionType([voidType, intType, voidType], voidType),
		builtParameter = builder.typeParameter(voidType),
		builtData = builtFunction.ref.data.ref.fun;
	var builtCorrect = builtData.ref.ret == voidType
		&& builtData.ref.args.offset(0).load() == voidType
		&& builtData.ref.args.offset(1).load() == intType
		&& builtData.ref.closure.ref.ret == voidType
		&& builtData.ref.closure.ref.args.offset(2).load() == voidType
		&& builtParameter.ref.data.ref.typeParam == voidType
		&& HlTypeBridge.native_type_kind(voidType) == 0
		&& HlTypeBridge.native_type_kind(builtFunction) == 10
		&& HlTypeBridge.native_type_kind(builtParameter) == 14
		&& HlTypeBridge.native_type_function_arity(builtFunction) == 3;
	var module = builder.moduleContext([
		RawPtr.nullPtr(),
		RawPtr.nullPtr(),
		RawPtr.nullPtr(),
		RawPtr.nullPtr(),
		RawPtr.nullPtr()
	], [intType, builtFunction, builtFunction, builtFunction, builtFunction]);
	var builtObject = builder.objectType(RawPtr.nullPtr(), RawPtr.nullPtr(), [{name: RawPtr.nullPtr(), type: intType, hashedName: 17}], [
		{
			name: RawPtr.nullPtr(),
			findex: 3,
			pindex: 4,
			hashedName: 19
		}
	], [7],
		RawPtr.nullPtr(), module, RawPtr.nullPtr()),
		objectData = builtObject.ref.data.ref.obj,
		builtEnum = builder.enumType(RawPtr.nullPtr(), [
			{
				name: RawPtr.nullPtr(),
				parameters: [intType],
				size: 4,
				hasPtr: false,
				offsets: [0]
			}
		],
			RawPtr.nullPtr()),
		enumData = builtEnum.ref.data.ref.enumType,
		builtVirtual = builder.virtualType([{name: RawPtr.nullPtr(), type: intType, hashedName: 23}], 4, [0], RawPtr.nullPtr()),
		virtualData = builtVirtual.ref.data.ref.virtualType;
	HlTypeBridge.native_type_initialize_enum(builtEnum, module);
	HlTypeBridge.native_type_initialize_virtual(builtVirtual, module);
	var graphCorrect = HlTypeBridge.native_type_kind(builtObject) == 11
		&& HlTypeBridge.native_type_object_field_count(builtObject) == 1
		&& objectData.ref.nfields == 1
		&& objectData.ref.fields.offset(0).ref.type == intType
		&& objectData.ref.fields.offset(0).ref.hashedName == 17
		&& objectData.ref.proto.offset(0).ref.findex == 3
		&& objectData.ref.bindings.offset(0).load() == 7
		&& HlTypeBridge.native_type_kind(builtEnum) == 18
		&& HlTypeBridge.native_type_enum_constructor_count(builtEnum) == 1
		&& enumData.ref.nconstructs == 1
		&& enumData.ref.constructs.offset(0).ref.params.offset(0).load() == intType
		&& enumData.ref.constructs.offset(0).ref.size == 16
		&& enumData.ref.constructs.offset(0).ref.offsets.offset(0).load() == 12
		&& HlTypeBridge.native_type_kind(builtVirtual) == 15
		&& HlTypeBridge.native_type_virtual_field_count(builtVirtual) == 1
		&& virtualData.ref.nfields == 1
		&& virtualData.ref.fields.offset(0).ref.type == intType
		&& virtualData.ref.indexes.offset(0).load() == 32
		&& virtualData.ref.dataSize == 4
		&& !virtualData.ref.lookup.isNull();
	var typeTable = new HlTypeTable(arena, 1),
		firstIndex = typeTable.add(voidType),
		secondIndex = typeTable.add(intType),
		thirdIndex = typeTable.add(builtFunction);
	var tableCorrect = firstIndex == 0 && secondIndex == 1 && thirdIndex == 2 && typeTable.length() == 3 && typeTable.capacityOf() == 4
		&& typeTable.get(0) == voidType && typeTable.get(1) == intType && typeTable.get(2) == builtFunction;
	typeTable.set(1, builtParameter);
	tableCorrect = tableCorrect && typeTable.get(1) == builtParameter;
	var objectName = builder.utf16Name("Obj"),
		fieldName = builder.utf16Name("field");
	objectData.ref.name = objectName;
	objectData.ref.fields.offset(0).ref.name = fieldName;
	var namesCorrect = objectData.ref.name.offset(0).load() == 79
		&& objectData.ref.name.offset(1).load() == 98
		&& objectData.ref.name.offset(2).load() == 106
		&& objectData.ref.name.offset(3).load() == 0
		&& objectData.ref.fields.offset(0).ref.name.offset(0).load() == 102
		&& objectData.ref.fields.offset(0).ref.name.offset(5).load() == 0;
	var moduleCorrect = !module.ref.alloc.ref.current.isNull()
		&& module.ref.functionsPtrs.offset(0).load() == RawPtr.nullPtr()
		&& module.ref.functionsTypes.offset(0).load() == intType;
	var nativeObjectCorrect = HlTypeBridge.native_type_data_size(builtObject) == 16
		&& HlTypeBridge.native_type_object_field_offset(builtObject, 0) == 8
		&& objectData.ref.module == module;
	var generation = new HlMetadataGeneration(128, 1),
		generationVoid = generation.builder.primitive(HlTypeKind.VoidType),
		generationInt = generation.builder.primitive(HlTypeKind.Int32Type),
		generationFunction = generation.builder.functionType([generationInt], generationVoid);
	generation.addType(generationVoid);
	generation.addType(generationFunction);
	var generationModule = generation.defineModule([RawPtr.nullPtr()], [generationFunction]),
		publication = generation.publish();
	var generationCorrect = publication.typeCount == 2
		&& publication.typeCapacity == 2
		&& publication.moduleContext == generationModule
		&& publication.types.offset(0).load() == generationVoid
		&& publication.types.offset(1).load() == generationFunction
		&& generation.type(1) == generationFunction;
	var generationSealed = false;
	try
		generation.addType(generationInt)
	catch (error:Dynamic)
		generationSealed = true;
	generation.dispose();
	arena.dispose();
	arena.dispose();
	return correct && builtCorrect && graphCorrect && tableCorrect && namesCorrect && moduleCorrect && nativeObjectCorrect && generationCorrect
		&& generationSealed ? 42 : 1;
}
