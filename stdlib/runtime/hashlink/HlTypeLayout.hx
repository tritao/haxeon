package runtime.hashlink;

import runtime.memory.RawPtr;
import runtime.memory.NativeFunctionPointer;
import runtime.hashlink.HlRuntimeObject.HlFieldLookup;
import runtime.hashlink.HlRuntimeObject.HlVirtualValue;
import runtime.hashlink.HlTypeObject.HlTypeEnum;
import runtime.hashlink.HlTypeObject.HlTypeVirtual;

/**
	Builds HashLink's derived layout and GC mark metadata in Haxe-owned storage.

	The arithmetic mirrors HashLink's ABI helpers and is Haxe-owned. Descriptor
	association and metadata layout remain in Haxeon; prototype method wiring is
	a native boundary because it publishes executable function pointers and
	closures. The non-moving object/enum/virtual layout is no longer built by the
	metadata publication loop in C.
*/
class HlTypeLayout {
	/**
		Attach Haxe-owned function descriptors to object prototypes and bindings.

		This is metadata policy, not executable-memory publication: the native
		boundary still fills method tables from the module's function pointers.
	 */
	public static function bindFunctionDescriptors(types:RawPtr<RawPtr<HlType>>, count:Int, functions:RawPtr<HlFunction>, functionCount:Int,
		context:RawPtr<HlModuleContext>):Void {
		if (count < 0 || (count > 0 && types.isNull()) || functionCount < 0 || (functionCount > 0 && functions.isNull()) || context.isNull())
			throw "HashLink function descriptor binding requires a type table, descriptors, and module context";
		for (index in 0...count) {
			var type = types.offset(index).load();
			if (type.isNull())
				throw 'HashLink metadata contains a null type at index $index';
			bindFunctionDescriptorsForType(type, functions, functionCount, context);
		}
	}

	/** Attach descriptors when the type records are one contiguous native slab. */
	public static function bindContiguousFunctionDescriptors(types:RawPtr<HlType>, count:Int, functions:RawPtr<HlFunction>, functionCount:Int,
		context:RawPtr<HlModuleContext>):Void {
		if (count < 0 || (count > 0 && types.isNull()) || functionCount < 0 || (functionCount > 0 && functions.isNull()) || context.isNull())
			throw "HashLink function descriptor binding requires a contiguous type slab, descriptors, and module context";
		for (index in 0...count)
			bindFunctionDescriptorsForType(types.offset(index), functions, functionCount, context);
	}

	/** Publish only object prototypes; Haxe-owned layout filters out other type kinds. */
	public static function publishObjectPrototypes(types:RawPtr<RawPtr<HlType>>, count:Int):Void {
		if (count < 0 || (count > 0 && types.isNull()))
			throw "HashLink object prototype publication requires a type table";
		for (index in 0...count)
			publishObjectPrototype(types.offset(index).load());
	}

	/** Publish object prototypes when the public type table is a contiguous native slab. */
	public static function publishContiguousObjectPrototypes(types:RawPtr<HlType>, count:Int):Void {
		if (count < 0 || (count > 0 && types.isNull()))
			throw "HashLink object prototype publication requires a contiguous type slab";
		for (index in 0...count)
			publishObjectPrototype(types.offset(index));
	}

	static function publishObjectPrototype(type:RawPtr<HlType>):Void {
		if (type.isNull())
			throw "HashLink object prototype publication contains a null type";
		var kind:HlTypeKind = cast type.ref.kind;
		if (kind == HlTypeKind.Object || kind == HlTypeKind.Struct)
			HlTypeBridge.native_metadata_publish_object_prototype(type);
	}

	static function bindFunctionDescriptorsForType(type:RawPtr<HlType>, functions:RawPtr<HlFunction>, functionCount:Int, context:RawPtr<HlModuleContext>):Void {
		var kind:HlTypeKind = cast type.ref.kind;
		if (kind != HlTypeKind.Object && kind != HlTypeKind.Struct)
			return;
		var object = type.ref.data.ref.obj;
		if (object.isNull())
			throw "HashLink function descriptor binding contains an invalid object";
		if ((cast(object.ref.nproto, Int) > 0 && object.ref.proto.isNull())
			|| (cast(object.ref.nbindings, Int) > 0 && object.ref.bindings.isNull()))
			throw "HashLink function descriptor binding contains incomplete object metadata";
		object.ref.module = context;
		var descriptor:RawPtr<HlFunction> = RawPtr.nullPtr();
		for (prototypeIndex in 0...cast(object.ref.nproto, Int)) {
			var prototype = object.ref.proto.offset(prototypeIndex);
			descriptor = findFunction(functions, functionCount, cast(prototype.ref.findex, Int));
			if (descriptor.isNull())
				throw "HashLink function descriptor binding references an unknown prototype";
			descriptor.ref.object = object;
			descriptor.ref.field.ref.name = prototype.ref.name;
		}
		for (bindingIndex in 0...cast(object.ref.nbindings, Int)) {
			var bindingOffset = bindingIndex * 2,
				fieldId:Int = cast object.ref.bindings.offset(bindingOffset).load(),
				functionId:Int = cast object.ref.bindings.offset(bindingOffset + 1).load(),
				field = objectField(type, fieldId);
			if (field.isNull())
				throw "HashLink function descriptor binding references an unknown field";
			if (field.ref.type.isNull())
				throw "HashLink function descriptor binding references a field without a type";
			var fieldKind:HlTypeKind = cast field.ref.type.ref.kind;
			if (fieldKind == HlTypeKind.Function || fieldKind == HlTypeKind.DynamicType) {
				descriptor = findFunction(functions, functionCount, functionId);
				if (descriptor.isNull())
					throw "HashLink function descriptor binding references an unknown method";
				descriptor.ref.object = object;
				descriptor.ref.field.ref.name = field.ref.name;
			}
		}
	}

	public static function initialize(types:RawPtr<RawPtr<HlType>>, count:Int, arena:HlTypeArena):Void {
		if (count < 0 || (count > 0 && types.isNull()) || arena == null)
			throw "HashLink type layout initialization requires a type table and arena";
		var complete:Array<RawPtr<HlType>> = [], active:Array<RawPtr<HlType>> = [];
		for (index in 0...count) {
			var type = types.offset(index).load();
			if (type.isNull())
				throw 'HashLink metadata contains a null type at index $index';
			initializeType(type, arena, complete, active);
		}
	}

	static function initializeType(type:RawPtr<HlType>, arena:HlTypeArena, complete:Array<RawPtr<HlType>>, active:Array<RawPtr<HlType>>):Void {
		if (type.isNull() || contains(complete, type))
			return;
		if (contains(active, type))
			throw "HashLink type layout contains a recursive non-layout edge";
		active.push(type);
		var kind:Int = cast type.ref.kind;
		if (kind == HlTypeKind.Object || kind == HlTypeKind.Struct)
			initializeObject(type, arena, complete, active);
		else if (kind == HlTypeKind.Enum)
			initializeEnum(type, arena);
		else if (kind == HlTypeKind.Virtual)
			initializeVirtual(type, arena);
		else if (kind == HlTypeKind.Packed)
			initializeType(type.ref.data.ref.typeParam, arena, complete, active);
		active.pop();
		complete.push(type);
	}

	static function initializeObject(type:RawPtr<HlType>, arena:HlTypeArena, complete:Array<RawPtr<HlType>>, active:Array<RawPtr<HlType>>):Void {
		var object = type.ref.data.ref.obj;
		if (object.isNull())
			throw 'HashLink object type has no object metadata (kind=${cast(type.ref.kind, Int)})';
		if (!object.ref.runtime.isNull())
			return;
		var parent = object.ref.superType, parentRuntime:RawPtr<HlRuntimeObject> = RawPtr.nullPtr();
		if (!parent.isNull()) {
			var parentKind:HlTypeKind = cast parent.ref.kind;
			if (parentKind != HlTypeKind.Object && parentKind != HlTypeKind.Struct)
				throw "HashLink object type has a non-object super type";
			initializeType(parent, arena, complete, active);
			parentRuntime = parent.ref.data.ref.obj.ref.runtime;
		}

		var ownFields = cast(object.ref.nfields, Int), ownPrototypes = cast(object.ref.nproto, Int), ownBindings = cast(object.ref.nbindings, Int),
			parentFields = parentRuntime.isNull() ? 0 : cast(parentRuntime.ref.nfields, Int),
			fieldCount = parentFields + ownFields,
			fieldIndexes:RawPtr<Int32> = fieldCount == 0 ? RawPtr.nullPtr() : arena.allocInt32Array(fieldCount),
			lookupCapacity = ownFields;
		if (!parentRuntime.isNull()) {
			for (index in 0...ownPrototypes) {
				var pindex:Int = cast(object.ref.proto.offset(index).ref.pindex, Int);
				if (pindex < 0 || pindex >= cast(parentRuntime.ref.nproto, Int))
					lookupCapacity++;
			}
		} else
			lookupCapacity += ownPrototypes;
		var lookups:RawPtr<HlFieldLookup> = lookupCapacity == 0 ? RawPtr.nullPtr() : arena.allocFieldLookupArray(lookupCapacity), lookupCount = 0;
		if (!parentRuntime.isNull() && fieldCount > 0)
			copyInts(fieldIndexes, parentRuntime.ref.fieldIndexes, parentFields);

		var pointerSize = HlTypeSemantics.pointerSize(), objectKind:HlTypeKind = cast type.ref.kind,
			size = parentRuntime.isNull() ? objectKind == HlTypeKind.Struct ? 0 : pointerSize : cast(parentRuntime.ref.size, Int) - cast(parentRuntime.ref.padSize, Int),
			largestField = parentRuntime.isNull() ? size : cast(parentRuntime.ref.largestField, Int),
			hasPtr = parentRuntime.isNull() ? false : parentRuntime.ref.hasPtr;
		for (index in 0...ownFields) {
			var field = object.ref.fields.offset(index), fieldType = field.ref.type;
			if (fieldType.isNull())
				throw 'HashLink object field $index has no type';
			var fieldIndex = parentFields + index;
			var fieldKind:HlTypeKind = cast fieldType.ref.kind;
			if (fieldKind == HlTypeKind.Packed) {
				initializeType(fieldType.ref.data.ref.typeParam, arena, complete, active);
				var packedRuntime = fieldType.ref.data.ref.typeParam.ref.data.ref.obj.ref.runtime,
					large = cast(packedRuntime.ref.largestField, Int);
				if (large > largestField)
					largestField = large;
				if (large > 0) {
					var padding = size % large;
					if (padding != 0)
						size += large - padding;
				}
				fieldIndexes.offset(fieldIndex).store(cast size);
				if (hasName(field.ref.name))
					lookupCount = insertLookup(lookups, lookupCount, cast(field.ref.hashedName, Int), fieldType, size);
				size += cast(packedRuntime.ref.size, Int);
				if (packedRuntime.ref.hasPtr)
					hasPtr = true;
			} else {
				size += HlTypeSemantics.padStruct(fieldType, size);
				fieldIndexes.offset(fieldIndex).store(cast size);
				if (hasName(field.ref.name))
					lookupCount = insertLookup(lookups, lookupCount, cast(field.ref.hashedName, Int), fieldType, size);
				var fieldSize = HlTypeSemantics.size(fieldType);
				size += fieldSize;
				if (fieldSize > largestField)
					largestField = fieldSize;
				if (!hasPtr && HlTypeSemantics.isPointer(fieldType))
					hasPtr = true;
			}
		}
		var padSize = largestField == 0 ? 0 : (largestField - size % largestField) % largestField;
		size += padSize;
		var runtime = arena.allocRuntimeObject();
		var inheritedPrototypes:Int = parentRuntime.isNull() ? 0 : cast(parentRuntime.ref.nproto, Int);
		var inheritedMethods:Int = parentRuntime.isNull() ? ownPrototypes : cast(parentRuntime.ref.nmethods, Int);
		runtime.ref.type = type;
		runtime.ref.nfields = cast fieldCount;
		runtime.ref.nproto = cast inheritedPrototypes;
		runtime.ref.size = cast size;
		runtime.ref.nmethods = cast inheritedMethods;
		var bindingCount = bindingCountFor(object, parentRuntime);
		var bindingStorage:RawPtr<HlRuntimeBinding> = bindingCount == 0 ? RawPtr.nullPtr() : arena.allocRuntimeBindingArray(bindingCount);
		runtime.ref.nbindings = cast bindingCount;
		runtime.ref.padSize = cast padSize;
		runtime.ref.largestField = cast largestField;
		runtime.ref.hasPtr = hasPtr;
		runtime.ref.methods = RawPtr.nullPtr();
	runtime.ref.fieldIndexes = fieldIndexes;
		runtime.ref.bindings = bindingStorage;
		initializeBindings(runtime.ref.bindings, bindingCount, object, parentRuntime);
	runtime.ref.parent = parentRuntime;
	runtime.ref.toStringFun = NativeFunctionPointer.nullPtr();
	runtime.ref.compareFun = NativeFunctionPointer.nullPtr();
	runtime.ref.castFun = NativeFunctionPointer.nullPtr();
	runtime.ref.getFieldFun = NativeFunctionPointer.nullPtr();
	runtime.ref.nlookup = cast lookupCount;
	runtime.ref.ninterfaces = 0;
	runtime.ref.lookup = lookups;
	object.ref.runtime = runtime;
	type.ref.vobjProto = RawPtr.nullPtr();

		var protoCount:Int = cast(runtime.ref.nproto, Int), nextMethod:Int = cast(runtime.ref.nmethods, Int);
		for (index in 0...ownPrototypes) {
			var proto = object.ref.proto.offset(index);
			var pindex:Int = cast(proto.ref.pindex, Int);
			if (!parentRuntime.isNull() && pindex >= 0 && pindex < cast(parentRuntime.ref.nproto, Int))
				continue;
			var methodIndex = parentRuntime.isNull() ? index : nextMethod++;
			if (pindex >= protoCount)
				protoCount = pindex + 1;
			if (object.ref.module.isNull())
				throw "HashLink object prototype has no module context";
			var functionType = object.ref.module.ref.functionsTypes.offset(cast(proto.ref.findex, Int)).load();
			lookupCount = insertLookup(lookups, lookupCount, cast(proto.ref.hashedName, Int), functionType, -(methodIndex + 1));
		}
		runtime.ref.nproto = cast protoCount;
		runtime.ref.nmethods = cast nextMethod;
		runtime.ref.nlookup = cast lookupCount;

	var interfaceCount = 0;
	for (index in 0...ownFields)
		if (object.ref.fields.offset(index).ref.hashedName == 0)
			interfaceCount++;
	var interfaceIndexes:RawPtr<Int32> = interfaceCount == 0 ? RawPtr.nullPtr() : arena.allocInt32Array(interfaceCount);
	runtime.ref.ninterfaces = cast interfaceCount;
	runtime.ref.interfaces = interfaceIndexes;
	var interfaceIndex = 0;
	for (index in 0...ownFields)
		if (object.ref.fields.offset(index).ref.hashedName == 0) {
			runtime.ref.interfaces.offset(interfaceIndex).store(cast index);
			interfaceIndex++;
		}
		initializeObjectMarkBits(type, runtime, parentRuntime, object, arena, pointerSize);
	}

	static function bindingCountFor(object:RawPtr<HlTypeObject>, parent:RawPtr<HlRuntimeObject>):Int {
		var ownCount = cast(object.ref.nbindings, Int), count = parent.isNull() ? 0 : cast(parent.ref.nbindings, Int);
		for (index in 0...ownCount) {
			var fieldId = cast(object.ref.bindings.offset(index * 2).load(), Int);
			if (parent.isNull() || bindingIndex(parent, fieldId) == -1)
				count++;
		}
		return count;
	}

	static function initializeBindings(bindings:RawPtr<HlRuntimeBinding>, count:Int, object:RawPtr<HlTypeObject>, parent:RawPtr<HlRuntimeObject>):Void {
		if (count == 0)
			return;
		if (bindings.isNull())
			throw "HashLink runtime binding storage is missing";
		var parentCount = parent.isNull() ? 0 : cast(parent.ref.nbindings, Int);
		if (!parent.isNull())
			for (index in 0...parentCount) {
				var source = parent.ref.bindings.offset(index), destination = bindings.offset(index);
				destination.ref.pointer = source.ref.pointer;
				destination.ref.closure = source.ref.closure;
				destination.ref.fieldId = source.ref.fieldId;
			}
		var next = parentCount, ownCount = cast(object.ref.nbindings, Int);
		for (index in 0...ownCount) {
			var fieldId = cast(object.ref.bindings.offset(index * 2).load(), Int), slot = parent.isNull() ? -1 : bindingIndex(parent, fieldId);
			if (slot == -1)
				slot = next++;
			var binding = bindings.offset(slot);
			binding.ref.pointer = RawPtr.nullPtr();
			binding.ref.closure = RawPtr.nullPtr();
			binding.ref.fieldId = cast fieldId;
		}
	}

	static function bindingIndex(runtime:RawPtr<HlRuntimeObject>, fieldId:Int):Int {
		for (index in 0...cast(runtime.ref.nbindings, Int))
			if (cast(runtime.ref.bindings.offset(index).ref.fieldId, Int) == fieldId)
				return index;
		return -1;
	}

	static function findFunction(functions:RawPtr<HlFunction>, count:Int, findex:Int):RawPtr<HlFunction> {
		for (index in 0...count) {
			var descriptor = functions.offset(index);
			if (cast(descriptor.ref.findex, Int) == findex)
				return descriptor;
		}
		return RawPtr.nullPtr();
	}

	static function objectField(type:RawPtr<HlType>, fieldId:Int):RawPtr<HlObjectField> {
		if (fieldId < 0)
			return RawPtr.nullPtr();
		var object = type.ref.data.ref.obj;
		if (object.isNull())
			return RawPtr.nullPtr();
		var parent = object.ref.superType;
		if (!parent.isNull()) {
			var parentRuntime = parent.ref.data.ref.obj.ref.runtime;
			if (parentRuntime.isNull())
				throw "HashLink object field lookup requires an initialized parent runtime";
			var parentFieldCount:Int = cast parentRuntime.ref.nfields;
			if (fieldId < parentFieldCount)
				return objectField(parent, fieldId);
			fieldId -= parentFieldCount;
		}
		var fieldCount:Int = cast object.ref.nfields;
		return fieldId >= fieldCount || object.ref.fields.isNull() ? RawPtr.nullPtr() : object.ref.fields.offset(fieldId);
	}

	static function initializeEnum(type:RawPtr<HlType>, arena:HlTypeArena):Void {
		var enumData = type.ref.data.ref.enumType;
		if (enumData.isNull())
			throw "HashLink enum type has no enum metadata";
		var pointerSize = HlTypeSemantics.pointerSize(), maxMarkSize = 0, count = cast(enumData.ref.nconstructs, Int);
		for (index in 0...count) {
			var construct = enumData.ref.constructs.offset(index), size = pointerSize + 4, hasPtr = false, parameterCount = cast(construct.ref.nparams, Int);
			for (parameter in 0...parameterCount) {
				var parameterType = construct.ref.params.offset(parameter).load();
				size += HlTypeSemantics.padStruct(parameterType, size);
				construct.ref.offsets.offset(parameter).store(cast size);
				if (HlTypeSemantics.isPointer(parameterType))
					hasPtr = true;
				size += HlTypeSemantics.size(parameterType);
			}
			construct.ref.size = cast size;
			construct.ref.hasPtr = hasPtr;
			if (hasPtr) {
				var bodySize = size - pointerSize * 2, markSize = HlTypeSemantics.markSize(bodySize);
				if (index * 4 + markSize > maxMarkSize)
					maxMarkSize = index * 4 + markSize;
			}
		}
		type.ref.markBits = allocateZeroedMarkBits(arena, maxMarkSize);
		if (type.ref.markBits.isNull())
			return;
		for (index in 0...count) {
			var construct = enumData.ref.constructs.offset(index);
			if (!construct.ref.hasPtr)
				continue;
			for (parameter in 0...cast(construct.ref.nparams, Int)) {
				var parameterType = construct.ref.params.offset(parameter).load();
				if (HlTypeSemantics.isPointer(parameterType)) {
				var position:Int = Std.int(cast(construct.ref.offsets.offset(parameter).load(), Int) / pointerSize) - 2;
					setMarkBit(type.ref.markBits, index + (position >> 5), position & 31);
				}
			}
		}
	}

	static function initializeVirtual(type:RawPtr<HlType>, arena:HlTypeArena):Void {
		var virtualData = type.ref.data.ref.virtualType;
		if (virtualData.isNull())
			throw "HashLink virtual type has no virtual metadata";
		var pointerSize = HlTypeSemantics.pointerSize(), count = cast(virtualData.ref.nfields, Int),
			vsize = sizeof<HlVirtualValue>() + pointerSize * count, size = vsize,
			lookups:RawPtr<HlFieldLookup> = count == 0 ? RawPtr.nullPtr() : arena.allocFieldLookupArray(count), indexes:RawPtr<Int32> = count == 0 ? RawPtr.nullPtr() : arena.allocInt32Array(count);
		for (index in 0...count) {
			var field = virtualData.ref.fields.offset(index), fieldType = field.ref.type;
			size += HlTypeSemantics.padStruct(fieldType, size);
			indexes.offset(index).store(cast size);
			insertLookup(lookups, index, cast(field.ref.hashedName, Int), fieldType, index);
			size += HlTypeSemantics.size(fieldType);
		}
		virtualData.ref.dataSize = cast(size - vsize);
		virtualData.ref.indexes = indexes;
		virtualData.ref.lookup = lookups;
		type.ref.markBits = allocateZeroedMarkBits(arena, HlTypeSemantics.markSize(size));
		if (!type.ref.markBits.isNull()) {
			setMarkBit(type.ref.markBits, 0, 1);
			setMarkBit(type.ref.markBits, 0, 2);
			for (index in 0...count)
				if (HlTypeSemantics.isPointer(virtualData.ref.fields.offset(index).ref.type)) {
					var position:Int = Std.int(cast(indexes.offset(index).load(), Int) / pointerSize);
					setMarkBit(type.ref.markBits, position >> 5, position & 31);
				}
		}
	}

	static function initializeObjectMarkBits(type:RawPtr<HlType>, runtime:RawPtr<HlRuntimeObject>, parent:RawPtr<HlRuntimeObject>, object:RawPtr<HlTypeObject>,
			arena:HlTypeArena, pointerSize:Int):Void {
		if (!runtime.ref.hasPtr) {
			type.ref.markBits = RawPtr.nullPtr();
			return;
		}
		var markSize = HlTypeSemantics.markSize(cast(runtime.ref.size, Int)), markBits = allocateZeroedMarkBits(arena, markSize);
		type.ref.markBits = markBits;
		if (!parent.isNull() && !parent.ref.type.ref.markBits.isNull())
			copyMarkBits(markBits, parent.ref.type.ref.markBits, HlTypeSemantics.markSize(cast(parent.ref.size, Int)) >> 2, 0);
		var parentFields = parent.isNull() ? 0 : cast(parent.ref.nfields, Int), fieldCount = cast(object.ref.nfields, Int);
		for (index in 0...fieldCount) {
			var fieldType = object.ref.fields.offset(index).ref.type, fieldIndex = cast(runtime.ref.fieldIndexes.offset(parentFields + index).load(), Int);
			var fieldKind:HlTypeKind = cast fieldType.ref.kind;
			if (fieldKind == HlTypeKind.Packed) {
				var packedRuntime = fieldType.ref.data.ref.typeParam.ref.data.ref.obj.ref.runtime;
				if (!packedRuntime.ref.type.ref.markBits.isNull())
					copyMarkBits(markBits, packedRuntime.ref.type.ref.markBits, HlTypeSemantics.markSize(cast(packedRuntime.ref.size, Int)) >> 2,
						pointerIndex(cast(fieldIndex, Int), pointerSize) >> 5);
			} else if (HlTypeSemantics.isPointer(fieldType)) {
				var position = pointerIndex(fieldIndex, pointerSize);
				setMarkBit(markBits, position >> 5, position & 31);
			}
		}
	}

	static function allocateZeroedMarkBits(arena:HlTypeArena, bytes:Int):RawPtr<UInt32> {
		if (bytes <= 0)
			return RawPtr.nullPtr();
		var words = (bytes + 3) >> 2, result = arena.allocUInt32Array(words);
		for (index in 0...words)
			result.offset(index).store(cast 0);
		return result;
	}

	static function copyMarkBits(destination:RawPtr<UInt32>, source:RawPtr<UInt32>, words:Int, destinationOffset:Int):Void {
		for (index in 0...words)
			destination.offset(destinationOffset + index).store(source.offset(index).load());
	}

	static function setMarkBit(markBits:RawPtr<UInt32>, word:Int, bit:Int):Void {
		var value:Int = cast(markBits.offset(word).load(), Int);
		markBits.offset(word).store(cast(value | (1 << bit)));
	}

	static function pointerIndex(byteOffset:Int, pointerSize:Int):Int
		return Std.int(byteOffset / pointerSize);

	static function copyInts(destination:RawPtr<Int32>, source:RawPtr<Int32>, count:Int):Void {
		for (index in 0...count)
			destination.offset(index).store(source.offset(index).load());
	}

	static function insertLookup(lookups:RawPtr<HlFieldLookup>, count:Int, hashedName:Int, type:RawPtr<HlType>, fieldIndex:Int):Int {
		var hash = hashedName, position = 0;
		while (position < count && cast(lookups.offset(position).ref.hashedName, Int) < hash)
			position++;
		var index = count;
		while (index > position) {
			var source = lookups.offset(index - 1), destination = lookups.offset(index);
			destination.ref.type = source.ref.type;
			destination.ref.hashedName = source.ref.hashedName;
			destination.ref.fieldIndex = source.ref.fieldIndex;
			index--;
		}
		lookups.offset(position).ref.type = type;
		lookups.offset(position).ref.hashedName = cast(hash, Int32);
		lookups.offset(position).ref.fieldIndex = cast(fieldIndex, Int32);
		return count + 1;
	}

	static function hasName(name:RawPtr<UInt16>):Bool
		return !name.isNull() && name.offset(0).load() != 0;

	static function contains(values:Array<RawPtr<HlType>>, target:RawPtr<HlType>):Bool {
		for (value in values)
			if (value == target)
				return true;
		return false;
	}
}
