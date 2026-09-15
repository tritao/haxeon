package compiler.hl;

import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlValidator;
import runtime.hashlink.HlMetadataGeneration;
import runtime.hashlink.HlTypeBuilder;
import runtime.hashlink.HlTypeKind;
import runtime.memory.RawPtr;

/**
	Imports one validated HLB type table into Haxe-owned HashLink metadata.

	The importer deliberately stops at the metadata/code boundary. Function
	descriptors carry dispatch and register signature information, while the
	native hl_opcode representation remains owned by the future code bridge.
 */
class HlNativeMetadataBuilder {
	/**
		Build, derive, and publish the native metadata graph for one HLB module.

		When supplied, functionPointers is indexed by the module's dispatch slot;
		missing slots are represented by null pointers until native code is
		installed. The returned generation owns every imported allocation.
	 */
	public static function build(code:HlCode, ?functionPointers:Array<RawPtr<UInt8>>):HlMetadataGeneration {
		if (code == null)
			throw "HashLink native metadata requires an HLB module";
		HlValidator.validate(code);
		var generation = new HlMetadataGeneration(65536, positive(code.types.length), 65536, positive(code.functions.length), positive(code.natives.length));
		try {
			var typePointers = allocateTypes(code, generation),
				functionCount = dispatchSlotCount(code),
				pointers = dispatchPointers(functionCount, functionPointers),
				functionTypes = dispatchTypes(code, typePointers, functionCount),
				module = generation.defineModule(pointers, functionTypes);
			for (index in 0...code.types.length)
				generation.addType(typePointers[index]);
			defineTypes(code, generation, typePointers, module);
			addFunctionDescriptors(code, generation, typePointers);
			addNativeDescriptors(code, generation, typePointers);
			generation.publish();
			return generation;
		} catch (error:Dynamic) {
			generation.dispose();
			throw error;
		}
	}

	static function allocateTypes(code:HlCode, generation:HlMetadataGeneration):Array<RawPtr<runtime.hashlink.HlType>> {
		var result:Array<RawPtr<runtime.hashlink.HlType>> = [];
		for (definition in code.types)
			result.push(allocateType(code, generation.builder, definition));
		return result;
	}

	static function allocateType(code:HlCode, builder:HlTypeBuilder, definition:HlTypeDef):RawPtr<runtime.hashlink.HlType> {
		return switch definition {
			case Simple(kind):
				builder.primitive(runtimeKind(kind));
			case Parameterized(kind, _):
				builder.parameterizedType(runtimeKind(kind), RawPtr.nullPtr());
			case Abstract(name):
				builder.abstractType(builder.utf16Name(code.strings[name]));
			case Function(_, _):
				builder.functionTypeSkeleton(HlTypeKind.Function);
			case Method(_, _):
				builder.functionTypeSkeleton(HlTypeKind.Method);
			case Object(_, _, _, _, _, _):
				builder.objectTypeSkeleton(HlTypeKind.Object);
			case Structure(_, _, _, _, _):
				builder.objectTypeSkeleton(HlTypeKind.Struct);
			case Virtual(_):
				builder.virtualTypeSkeleton();
			case Enum(_, _, _):
				builder.enumTypeSkeleton();
		};
	}

	static function defineTypes(code:HlCode, generation:HlMetadataGeneration, types:Array<RawPtr<runtime.hashlink.HlType>>,
			module:RawPtr<runtime.hashlink.HlModuleContext>):Void {
		for (index in 0...code.types.length)
			switch code.types[index] {
				case Simple(_):
				case Parameterized(kind, parameter):
					types[index].ref.data.ref.typeParam = types[parameter];
				case Abstract(_):
				case Function(arguments, result), Method(arguments, result):
					generation.builder.defineFunctionType(types[index], typePointers(types, arguments), types[result]);
				case Object(name, base, global, fields, methods, bindings):
					defineObject(code, generation, types[index], name, base, global, fields, methods, bindings, module, false, types);
				case Structure(name, global, fields, methods, bindings):
					defineObject(code, generation, types[index], name, -1, global, fields, methods, bindings, module, true, types);
				case Virtual(fields):
					generation.builder.defineVirtualType(types[index], objectFields(code, generation.builder, fields, types), 0, [for (_ in fields) 0],
						RawPtr.nullPtr());
				case Enum(name, global, constructors):
					generation.builder.defineEnumType(types[index], generation.builder.utf16Name(code.strings[name]),
						enumConstructors(code, generation, constructors, types), globalPointer(generation, global));
			}
	}

	static function defineObject(code:HlCode, generation:HlMetadataGeneration, type:RawPtr<runtime.hashlink.HlType>, name:Int, base:Int, global:Int,
			fields:Array<HlCode.HlObjectField>, methods:Array<HlCode.HlObjectMethod>, bindings:Array<Int>, module:RawPtr<runtime.hashlink.HlModuleContext>,
			structure:Bool, types:Array<RawPtr<runtime.hashlink.HlType>>):Void {
		if (bindings.length % 2 != 0)
			throw 'HashLink object type $name has an incomplete binding pair';
		var objectBindings:Array<runtime.hashlink.HlTypeBuilder.HlObjectBindingSpec> = [];
		for (index in 0...Std.int(bindings.length / 2)) {
			var fieldIndex = bindings[index * 2],
				functionIndex = bindings[index * 2 + 1];
			if (fieldIndex < 0 || fieldIndex >= fields.length || functionIndex < 0)
				throw 'HashLink object type $name has an invalid binding ($fieldIndex, $functionIndex)';
			objectBindings.push({fieldIndex: fieldIndex, functionIndex: functionIndex});
		}
		var objectType = structure ? HlTypeKind.Struct : HlTypeKind.Object;
		var actualType:HlTypeKind = cast type.ref.kind;
		if (actualType != objectType)
			throw "HashLink object definition kind does not match its type skeleton";
		generation.builder.defineObjectType(type, generation.builder.utf16Name(code.strings[name]), base < 0 ? RawPtr.nullPtr() : types[base],
			objectFields(code, generation.builder, fields, types), objectPrototypes(code, generation.builder, methods), objectBindings,
			globalPointer(generation, global), module, RawPtr.nullPtr());
	}

	static function objectFields(code:HlCode, builder:HlTypeBuilder, fields:Array<HlCode.HlObjectField>,
			types:Array<RawPtr<runtime.hashlink.HlType>>):Array<runtime.hashlink.HlTypeBuilder.HlObjectFieldSpec> {
		var result:Array<runtime.hashlink.HlTypeBuilder.HlObjectFieldSpec> = [];
		for (field in fields) {
			var fieldName = code.strings[field.name];
			result.push({name: builder.utf16Name(fieldName), type: types[field.type], hashedName: HlTypeBuilder.hashUtf16(fieldName)});
		}
		return result;
	}

	static function objectPrototypes(code:HlCode, builder:HlTypeBuilder,
			methods:Array<HlCode.HlObjectMethod>):Array<runtime.hashlink.HlTypeBuilder.HlObjectProtoSpec> {
		var result:Array<runtime.hashlink.HlTypeBuilder.HlObjectProtoSpec> = [];
		for (method in methods) {
			var methodName = code.strings[method.name];
			result.push({
				name: builder.utf16Name(methodName),
				findex: method.functionIndex,
				pindex: method.prototype,
				hashedName: HlTypeBuilder.hashUtf16(methodName)
			});
		}
		return result;
	}

	static function enumConstructors(code:HlCode, generation:HlMetadataGeneration, constructors:Array<HlCode.HlEnumConstructor>,
			types:Array<RawPtr<runtime.hashlink.HlType>>):Array<runtime.hashlink.HlTypeBuilder.HlEnumConstructSpec> {
		var result:Array<runtime.hashlink.HlTypeBuilder.HlEnumConstructSpec> = [];
		for (constructor in constructors) {
			var parameters = typePointers(types, constructor.params);
			result.push({
				name: generation.builder.utf16Name(code.strings[constructor.name]),
				parameters: parameters,
				size: 0,
				hasPtr: false,
				offsets: [for (_ in parameters) 0]
			});
		}
		return result;
	}

	static function addFunctionDescriptors(code:HlCode, generation:HlMetadataGeneration, types:Array<RawPtr<runtime.hashlink.HlType>>):Void {
		for (fn in code.functions) {
			var registers:RawPtr<RawPtr<runtime.hashlink.HlType>> = fn.registers.length == 0 ? RawPtr.nullPtr() : generation.arena.allocTypePointerArray(fn.registers.length);
			for (index in 0...fn.registers.length)
				registers.offset(index).store(types[fn.registers[index]]);
			generation.addFunctionDescriptor({
				findex: fn.functionIndex,
				nregs: fn.registers.length,
				nops: 0,
				reference: 0,
				nassigns: 0,
				type: types[fn.type],
				regs: registers,
				ops: RawPtr.nullPtr(),
				debug: RawPtr.nullPtr(),
				assigns: RawPtr.nullPtr(),
				object: RawPtr.nullPtr(),
				fieldName: RawPtr.nullPtr(),
				fieldReference: RawPtr.nullPtr()
			});
		}
	}

	static function addNativeDescriptors(code:HlCode, generation:HlMetadataGeneration, types:Array<RawPtr<runtime.hashlink.HlType>>):Void {
		for (native in code.natives)
			generation.addNativeDescriptor({
				library: generation.builder.utf8Name(code.strings[native.library]),
				name: generation.builder.utf8Name(code.strings[native.name]),
				type: types[native.type],
				findex: native.functionIndex
			});
	}

	static function dispatchSlotCount(code:HlCode):Int {
		var maximum = -1;
		for (native in code.natives)
			if (native.functionIndex > maximum)
				maximum = native.functionIndex;
		for (fn in code.functions)
			if (fn.functionIndex > maximum)
				maximum = fn.functionIndex;
		return maximum + 1;
	}

	static function dispatchPointers(count:Int, supplied:Null<Array<RawPtr<UInt8>>>):Array<RawPtr<UInt8>> {
		if (supplied != null && supplied.length != count)
			throw 'HashLink function pointer table has ${supplied.length} entries, expected $count';
		var result:Array<RawPtr<UInt8>> = [];
		for (index in 0...count)
			result.push(supplied == null ? RawPtr.nullPtr() : supplied[index]);
		return result;
	}

	static function dispatchTypes(code:HlCode, types:Array<RawPtr<runtime.hashlink.HlType>>, count:Int):Array<RawPtr<runtime.hashlink.HlType>> {
		var result:Array<RawPtr<runtime.hashlink.HlType>> = [];
		for (_ in 0...count)
			result.push(RawPtr.nullPtr());
		for (native in code.natives)
			result[native.functionIndex] = types[native.type];
		for (fn in code.functions)
			result[fn.functionIndex] = types[fn.type];
		return result;
	}

	static function typePointers(types:Array<RawPtr<runtime.hashlink.HlType>>, indices:Array<Int>):Array<RawPtr<runtime.hashlink.HlType>> {
		var result:Array<RawPtr<runtime.hashlink.HlType>> = [];
		for (index in indices)
			result.push(types[index]);
		return result;
	}

	static function globalPointer(generation:HlMetadataGeneration, index:Int):RawPtr<RawPtr<UInt8>> {
		if (index == 0)
			return RawPtr.nullPtr();
		var result = generation.arena.allocNativePointerArray(1);
		result.offset(0).store(RawPtr.nullPtr());
		return result;
	}

	static function runtimeKind(kind:HlType):HlTypeKind {
		return switch kind {
			case HlType.Void: HlTypeKind.VoidType;
			case HlType.Ui8: HlTypeKind.UInt8Type;
			case HlType.Ui16: HlTypeKind.UInt16Type;
			case HlType.I32: HlTypeKind.Int32Type;
			case HlType.I64: HlTypeKind.Int64Type;
			case HlType.F32: HlTypeKind.Float32Type;
			case HlType.F64: HlTypeKind.Float64Type;
			case HlType.Bool: HlTypeKind.BoolType;
			case HlType.Bytes: HlTypeKind.BytesType;
			case HlType.Dyn: HlTypeKind.DynamicType;
			case HlType.Fun: HlTypeKind.Function;
			case HlType.Obj: HlTypeKind.Object;
			case HlType.Array: HlTypeKind.Array;
			case HlType.Type: HlTypeKind.Type;
			case HlType.Ref: HlTypeKind.Reference;
			case HlType.Virtual: HlTypeKind.Virtual;
			case HlType.DynObj: HlTypeKind.DynamicObject;
			case HlType.Abstract: HlTypeKind.Abstract;
			case HlType.Enum: HlTypeKind.Enum;
			case HlType.Null: HlTypeKind.Nullable;
			case HlType.Method: HlTypeKind.Method;
			case HlType.Struct: HlTypeKind.Struct;
			case HlType.Packed: HlTypeKind.Packed;
			case HlType.Guid: HlTypeKind.Guid;
			case _: throw 'Unknown HashLink type kind $kind';
		};
	}

	static inline function positive(value:Int):Int
		return value <= 0 ? 1 : value;
}
