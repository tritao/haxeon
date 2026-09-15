import runtime.hashlink.HlTypeArena;
import runtime.hashlink.HlTypeBridge;
import runtime.hashlink.HlTypeBuilder;
import runtime.hashlink.HlTypeLayout;
import runtime.hashlink.HlTypeTable;
import runtime.hashlink.HlType;
import runtime.hashlink.HlTypeKind;
import runtime.hashlink.HlMetadataGeneration;
import runtime.hashlink.HlFunctionTable;
import runtime.hashlink.HlFunctionDescriptorTable;
import runtime.hashlink.HlFunction;
import runtime.memory.RawPtr;

function main():Int {
	var arena = new HlTypeArena(128, 32),
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
	var correct = type.ref.kind == 7 && storedFunction == functionType && storedTypeParam == type && reused.ref.kind == 7 && reused == arena.typePointer()
		&& arena.typeCapacityOf() == 32 && arena.typeCountOf() == 1 && nativeKind == 10 && nativeSize == 8 && nativeArity == 2;
	arena.reset();
	var voidType = builder.primitive(HlTypeKind.VoidType),
		intType = builder.primitive(HlTypeKind.Int32Type),
		builtFunction = builder.functionType([voidType, intType, voidType], voidType),
		builtParameter = builder.typeParameter(voidType),
		builtData = builtFunction.ref.data.ref.fun;
	var builtCorrect = builtData.ref.ret == voidType
		&& builtData.ref.args.offset(0).load() == voidType
		&& builtData.ref.args.offset(1).load() == intType
		&& builtData.ref.closure.ref.ret.isNull()
		&& builtData.ref.closure.ref.args.isNull()
		&& builtParameter.ref.data.ref.typeParam == voidType
		&& HlTypeBridge.native_type_kind(voidType) == 0
		&& HlTypeBridge.native_type_kind(builtFunction) == 10
		&& HlTypeBridge.native_type_kind(builtParameter) == 14
		&& HlTypeBridge.native_type_function_arity(builtFunction) == 3;
	var descriptorTable = new HlFunctionDescriptorTable(arena, 2),
		descriptorName = builder.utf16Name("descriptor"),
		descriptor = descriptorTable.add({
			findex: 7,
			nregs: 3,
			nops: 5,
			reference: 0,
			nassigns: 0,
			type: builtFunction,
			regs: builtData.ref.args,
			ops: RawPtr.nullPtr(),
			debug: RawPtr.nullPtr(),
			assigns: RawPtr.nullPtr(),
			object: RawPtr.nullPtr(),
			fieldName: descriptorName,
			fieldReference: RawPtr.nullPtr()
		}),
		descriptorReference = descriptorTable.add({
			findex: 8,
			nregs: 0,
			nops: 0,
			reference: 1,
			nassigns: 0,
			type: builtFunction,
			regs: RawPtr.nullPtr(),
			ops: RawPtr.nullPtr(),
			debug: RawPtr.nullPtr(),
			assigns: RawPtr.nullPtr(),
			object: RawPtr.nullPtr(),
			fieldName: RawPtr.nullPtr(),
			fieldReference: descriptor
		});
	var descriptorCorrect = descriptorTable.length() == 2
		&& descriptorTable.capacityOf() == 2
		&& descriptorTable.pointer() == descriptor
		&& descriptorReference == descriptor.offset(1)
		&& descriptor.ref.findex == 7
		&& descriptor.ref.nregs == 3
		&& descriptor.ref.nops == 5
		&& descriptor.ref.type == builtFunction
		&& descriptor.ref.regs == builtData.ref.args
		&& descriptor.ref.field.ref.name == descriptorName
		&& descriptorReference.ref.findex == 8
		&& descriptorReference.ref.reference == 1
		&& descriptorReference.ref.field.ref.reference == descriptor;
	var module = builder.moduleContext([
		RawPtr.nullPtr(),
		RawPtr.nullPtr(),
		RawPtr.nullPtr(),
		RawPtr.nullPtr(),
		RawPtr.nullPtr()
	], [intType, builtFunction, builtFunction, builtFunction, builtFunction]);
	var functionTable = new HlFunctionTable(arena, [RawPtr.nullPtr()], [builtFunction]),
		tableModule = builder.moduleContextFromTable(functionTable),
		functionTableCorrect = functionTable.length() == 1
			&& functionTable.functionAt(0) == RawPtr.nullPtr()
			&& functionTable.typeAt(0) == builtFunction
			&& tableModule.ref.functionsPtrs == functionTable.functionPointer()
			&& tableModule.ref.functionsTypes == functionTable.typePointer();
	var builtObject = builder.objectType(RawPtr.nullPtr(), RawPtr.nullPtr(), [{name: RawPtr.nullPtr(), type: builtFunction, hashedName: 17}], [
		{
			name: RawPtr.nullPtr(),
			findex: 3,
			pindex: 4,
			hashedName: 19
		}
	],
		[{fieldIndex: 0, functionIndex: 3}], RawPtr.nullPtr(), module, RawPtr.nullPtr()),
		objectData = builtObject.ref.data.ref.obj;
	var recursiveObject = builder.objectTypeSkeleton();
	builder.defineObjectType(recursiveObject, builder.utf16Name("RecursiveObject"), RawPtr.nullPtr(),
		[{name: builder.utf16Name("next"), type: recursiveObject, hashedName: 29}], [], [], RawPtr.nullPtr(), module, RawPtr.nullPtr());
	var recursiveObjectData = recursiveObject.ref.data.ref.obj,
		recursiveFunction = builder.functionTypeSkeleton();
	builder.defineFunctionType(recursiveFunction, [recursiveFunction], recursiveFunction);
	var recursiveEnum = builder.enumTypeSkeleton();
	builder.defineEnumType(recursiveEnum, builder.utf16Name("RecursiveEnum"), [
		{
			name: builder.utf16Name("self"),
			parameters: [recursiveEnum],
			size: 0,
			hasPtr: true,
			offsets: [0]
		}
	], RawPtr.nullPtr());
	var recursiveVirtual = builder.virtualTypeSkeleton();
	builder.defineVirtualType(recursiveVirtual, [{name: builder.utf16Name("value"), type: recursiveVirtual, hashedName: 31}], 0, [0], RawPtr.nullPtr());
	var recursiveFunctionData = recursiveFunction.ref.data.ref.fun,
		recursiveEnumData = recursiveEnum.ref.data.ref.enumType,
		recursiveVirtualData = recursiveVirtual.ref.data.ref.virtualType,
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
	var derivedTable = new HlTypeTable(arena, 4);
	derivedTable.add(builtObject);
	derivedTable.add(recursiveObject);
	derivedTable.add(builtEnum);
	derivedTable.add(builtVirtual);
	HlTypeLayout.initialize(derivedTable.pointer(), derivedTable.length(), arena);
	var graphCorrect = HlTypeBridge.native_type_kind(builtObject) == 11
		&& HlTypeBridge.native_type_object_field_count(builtObject) == 1
		&& objectData.ref.nfields == 1
		&& objectData.ref.fields.offset(0).ref.type == builtFunction
		&& objectData.ref.fields.offset(0).ref.hashedName == 17
		&& objectData.ref.proto.offset(0).ref.findex == 3
		&& objectData.ref.nbindings == 1
		&& objectData.ref.bindings.offset(0).load() == 0
		&& objectData.ref.bindings.offset(1).load() == 3
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
	HlTypeBridge.native_type_initialize_object(builtObject);
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
		&& objectData.ref.module == module
		&& !builtObject.ref.vobjProto.isNull()
		&& !objectData.ref.runtime.isNull()
		&& objectData.ref.runtime.ref.nmethods == 1
		&& objectData.ref.runtime.ref.nbindings == 1
		&& !objectData.ref.runtime.ref.bindings.offset(0).ref.pointer.isNull()
		&& objectData.ref.runtime.ref.bindings.offset(0).ref.fieldId == 0
		&& recursiveObjectData.ref.fields.offset(0).ref.type == recursiveObject
		&& recursiveObjectData.ref.fields.offset(0).ref.name.offset(0).load() == 110
		&& recursiveFunctionData.ref.args.offset(0).load() == recursiveFunction
		&& recursiveFunctionData.ref.ret == recursiveFunction
		&& recursiveEnumData.ref.constructs.offset(0).ref.params.offset(0).load() == recursiveEnum
		&& recursiveVirtualData.ref.fields.offset(0).ref.type == recursiveVirtual;
	HlTypeBridge.native_type_initialize_object(recursiveObject);
	nativeObjectCorrect = nativeObjectCorrect
		&& !recursiveObjectData.ref.runtime.isNull()
		&& HlTypeBridge.native_type_data_size(recursiveObject) == 16;
	var generation = new HlMetadataGeneration(128, 1),
		generationVoid = generation.builder.primitive(HlTypeKind.VoidType),
		generationInt = generation.builder.primitive(HlTypeKind.Int32Type),
		generationFunction = generation.builder.functionType([generationInt], generationVoid);
	var generationModule = generation.defineModule([RawPtr.nullPtr()], [generationFunction]),
		generationObject = generation.builder.objectType(generation.builder.utf16Name("GenerationObject"), RawPtr.nullPtr(), [], [], [], RawPtr.nullPtr(),
			generationModule, RawPtr.nullPtr()),
		generationObjectData = generationObject.ref.data.ref.obj;
	generation.addType(generationVoid);
	generation.addType(generationFunction);
	generation.addType(generationObject);
	var generationDescriptor = generation.addFunctionDescriptor({
		findex: 3,
		nregs: 1,
		nops: 2,
		reference: 0,
		nassigns: 0,
		type: generationFunction,
		regs: RawPtr.nullPtr(),
		ops: RawPtr.nullPtr(),
		debug: RawPtr.nullPtr(),
		assigns: RawPtr.nullPtr(),
		object: RawPtr.nullPtr(),
		fieldName: RawPtr.nullPtr(),
		fieldReference: RawPtr.nullPtr()
	});
	var publication = generation.publish();
	var generationCorrect = publication.typeCount == 3
		&& publication.typeCapacity == 4
		&& publication.contiguousTypes == generation.contiguousTypePointer()
		&& publication.contiguousTypeCount == 4
		&& publication.contiguousTypeCapacity == 65536
		&& !publication.usesContiguousTypes
		&& publication.functionDescriptors == generationDescriptor
		&& publication.functionDescriptorCount == 1
		&& publication.functionDescriptorCapacity == 8
		&& publication.functionCount == 1
		&& publication.moduleContext == generationModule
		&& publication.functions.offset(0).load() == RawPtr.nullPtr()
		&& publication.functionTypes.offset(0).load() == generationFunction
		&& publication.types.offset(0).load() == generationVoid
		&& publication.types.offset(1).load() == generationFunction
		&& publication.types.offset(2).load() == generationObject
		&& !generationObjectData.ref.runtime.isNull()
		&& generation.type(1) == generationFunction;
	var generationSealed = false;
	try
		generation.addType(generationInt)
	catch (error:Dynamic)
		generationSealed = true;
	generation.dispose();
	arena.dispose();
	arena.dispose();
	return correct && builtCorrect && descriptorCorrect && graphCorrect && tableCorrect && functionTableCorrect && namesCorrect && moduleCorrect
		&& nativeObjectCorrect && generationCorrect && generationSealed ? 42 : 1;
}
