import runtime.hashlink.HlMetadataGeneration;
import runtime.hashlink.HlRuntimeObject.HlVirtualValue;
import runtime.hashlink.HlTypeBridge;
import runtime.hashlink.HlTypeSemantics;
import runtime.hashlink.HlTypeKind;
import runtime.hashlink.HlTypeObject.HlTypeEnum;
import runtime.hashlink.HlTypeObject.HlTypeVirtual;
import runtime.memory.RawPtr;

function main():Int {
	var generation = new HlMetadataGeneration(128, 1),
		intType = generation.builder.primitive(HlTypeKind.Int32Type),
		dynamicType = generation.builder.primitive(HlTypeKind.DynamicType),
		module = generation.defineModule([], []),
		object = generation.builder.objectType(generation.builder.utf16Name("LayoutObject"), RawPtr.nullPtr(), [
			{
				name: generation.builder.utf16Name("number"),
				type: intType,
				hashedName: 17
			},
			{
				name: generation.builder.utf16Name("value"),
				type: dynamicType,
				hashedName: 23
			}
		], [], [],
			RawPtr.nullPtr(), module, RawPtr.nullPtr()),
		enumType = generation.builder.enumType(generation.builder.utf16Name("LayoutEnum"), [
			{
				name: generation.builder.utf16Name("Value"),
				parameters: [dynamicType],
				size: 0,
				hasPtr: false,
				offsets: [0]
			}
		], RawPtr.nullPtr()),
		virtualType = generation.builder.virtualType([
			{
				name: generation.builder.utf16Name("number"),
				type: intType,
				hashedName: 17
			},
			{
				name: generation.builder.utf16Name("value"),
				type: dynamicType,
				hashedName: 23
			}
		], 0, [], RawPtr.nullPtr());
	generation.addType(intType);
	generation.addType(dynamicType);
	generation.addType(object);
	generation.addType(enumType);
	generation.addType(virtualType);
	var publication = generation.publish();

	var objectData = object.ref.data.ref.obj,
		objectRuntime = objectData.ref.runtime,
		typeBase = generation.contiguousTypePointer(),
		enumData:RawPtr<HlTypeEnum> = enumType.ref.data.ref.enumType,
		virtualData:RawPtr<HlTypeVirtual> = virtualType.ref.data.ref.virtualType,
		objectMark = object.ref.markBits.isNull() ? 0 : cast(object.ref.markBits.offset(0).load(), Int),
		enumMark = enumType.ref.markBits.isNull() ? 0 : cast(enumType.ref.markBits.offset(0).load(), Int),
		virtualMark = virtualType.ref.markBits.isNull() ? 0 : cast(virtualType.ref.markBits.offset(0).load(), Int),
		pointerSize = HlTypeSemantics.pointerSize(),
		virtualHeaderSize = sizeof<HlVirtualValue>(),
		virtualBase = virtualHeaderSize + pointerSize * 2;
	var objectCorrect = !objectRuntime.isNull()
		&& publication.usesContiguousTypes
		&& intType == typeBase
		&& dynamicType == typeBase.offset(1)
		&& object == typeBase.offset(2)
		&& enumType == typeBase.offset(3)
		&& virtualType == typeBase.offset(4)
		&& objectRuntime.ref.nfields == 2
		&& objectRuntime.ref.size == 24
		&& objectRuntime.ref.fieldIndexes.offset(0).load() == 8
		&& objectRuntime.ref.fieldIndexes.offset(1).load() == 16
		&& objectRuntime.ref.nlookup == 2
		&& objectRuntime.ref.lookup.offset(0).ref.hashedName == 17
		&& objectRuntime.ref.lookup.offset(1).ref.hashedName == 23
		&& objectMark == 4;
	var enumCorrect = enumData.ref.constructs.offset(0).ref.size == 24
		&& enumData.ref.constructs.offset(0).ref.offsets.offset(0).load() == 16
		&& enumData.ref.constructs.offset(0).ref.hasPtr
		&& enumMark == 1;
	var virtualCorrect = virtualData.ref.dataSize == 16
		&& cast(virtualData.ref.indexes.offset(0)
			.load(), Int) == virtualBase
			&& cast(virtualData.ref.indexes.offset(1).load(), Int) == virtualBase
				+ 8
				&& virtualData.ref.lookup.offset(0).ref.hashedName == 17
				&& virtualData.ref.lookup.offset(1).ref.hashedName == 23
				&& virtualMark == 70
				&& pointerSize == 8;
	var correct = objectCorrect && enumCorrect && virtualCorrect;
	generation.dispose();
	return correct ? 42 : 1;
}
