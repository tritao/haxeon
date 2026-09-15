package compiler.hl;

import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlValidator;
import compiler.hl.HlOpcode;
import compiler.hl.HlFunction.HlDebugLocation;
import compiler.hl.HlWriter;
import runtime.hashlink.HlMetadataGeneration;
import runtime.hashlink.HlTypeBuilder;
import runtime.hashlink.HlTypeKind;
import runtime.memory.RawPtr;

/** Imports one validated HLB module into Haxe-owned HashLink metadata. */
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
		var generation = new HlMetadataGeneration(65536, positive(code.types.length), 65536, positive(code.functions.length), positive(code.natives.length),
			positive(code.constants.length), positive(code.debugSections.length));
		try {
			var typePointers = allocateTypes(code, generation),
				functionCount = dispatchSlotCount(code),
				pointers = dispatchPointers(functionCount, functionPointers),
				functionTypes = dispatchTypes(code, typePointers, functionCount),
				module = generation.defineModule(pointers, functionTypes),
				globals = generation.defineGlobalTypes([for (global in code.globals) typePointers[global]]);
			generation.defineModulePools(new runtime.hashlink.HlModulePools(generation.arena, generation.builder, code.ints, code.floats, code.strings,
				code.bytes, code.bytePositions, code.entryPoint));
			generation.defineDebugFiles(debugFilePaths(code));
			for (section in code.debugSections)
				generation.addDebugSection({
					kind: section.kind,
					version: section.version,
					flags: section.flags,
					payload: section.payload
				});
			for (index in 0...code.types.length)
				generation.addType(typePointers[index]);
			defineTypes(code, generation, typePointers, module, globals);
			addFunctionDescriptors(code, generation, typePointers);
			addNativeDescriptors(code, generation, typePointers);
			addConstants(code, generation);
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
			module:RawPtr<runtime.hashlink.HlModuleContext>, globals:RawPtr<RawPtr<UInt8>>):Void {
		for (index in 0...code.types.length)
			switch code.types[index] {
				case Simple(_):
				case Parameterized(kind, parameter):
					types[index].ref.data.ref.typeParam = types[parameter];
				case Abstract(_):
				case Function(arguments, result), Method(arguments, result):
					generation.builder.defineFunctionType(types[index], typePointers(types, arguments), types[result]);
				case Object(name, base, global, fields, methods, bindings):
					defineObject(code, generation, types[index], name, base, global, fields, methods, bindings, module, globals, false, types);
				case Structure(name, global, fields, methods, bindings):
					defineObject(code, generation, types[index], name, -1, global, fields, methods, bindings, module, globals, true, types);
				case Virtual(fields):
					generation.builder.defineVirtualType(types[index], objectFields(code, generation.builder, fields, types), 0, [for (_ in fields) 0],
						RawPtr.nullPtr());
				case Enum(name, global, constructors):
					generation.builder.defineEnumType(types[index], generation.builder.utf16Name(code.strings[name]),
						enumConstructors(code, generation, constructors, types), generation.globalPointer(global));
			}
	}

	static function defineObject(code:HlCode, generation:HlMetadataGeneration, type:RawPtr<runtime.hashlink.HlType>, name:Int, base:Int, global:Int,
			fields:Array<HlCode.HlObjectField>, methods:Array<HlCode.HlObjectMethod>, bindings:Array<Int>, module:RawPtr<runtime.hashlink.HlModuleContext>,
			globals:RawPtr<RawPtr<UInt8>>, structure:Bool, types:Array<RawPtr<runtime.hashlink.HlType>>):Void {
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
			global == 0 ? RawPtr.nullPtr() : globals.offset(global - 1), module, RawPtr.nullPtr());
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
			var encoded = HlWriter.lower(fn),
				ops:RawPtr<runtime.hashlink.HlOpcode> = encoded.length == 0 ? RawPtr.nullPtr() : generation.arena.allocOpcodeArray(encoded.length);
			for (index in 0...encoded.length)
				writeOpcode(ops.offset(index), encoded[index], generation);
			var debug:RawPtr<Int32> = encoded.length == 0
				|| generation.debugFileCountOf() == 0 ? RawPtr.nullPtr() : generation.arena.allocInt32Array(encoded.length * 2);
			if (!debug.isNull())
				for (index in 0...encoded.length) {
					var location = debugLocation(fn, index);
					debug.offset(index * 2).store(cast generation.debugFileIndex(location.path));
					debug.offset(index * 2 + 1).store(cast location.line);
				}
			var assigns:RawPtr<Int32> = fn.debugAssignments.length == 0 ? RawPtr.nullPtr() : generation.arena.allocInt32Array(fn.debugAssignments.length * 3);
			for (index in 0...fn.debugAssignments.length) {
				var assignment = fn.debugAssignments[index];
				if (assignment.name < 0 || assignment.name >= code.strings.length)
					throw 'HashLink function ${fn.functionIndex} has an invalid debug assignment name';
				assigns.offset(index * 3).store(cast assignment.name);
				assigns.offset(index * 3 + 1).store(cast assignment.position);
				assigns.offset(index * 3 + 2).store(cast assignment.scopeEnd);
			}
			generation.addFunctionDescriptor({
				findex: fn.functionIndex,
				nregs: fn.registers.length,
				nops: encoded.length,
				reference: 0,
				nassigns: fn.debugAssignments.length,
				type: types[fn.type],
				regs: registers,
				ops: ops,
				debug: debug,
				assigns: assigns,
				object: RawPtr.nullPtr(),
				fieldName: RawPtr.nullPtr(),
				fieldReference: RawPtr.nullPtr()
			});
		}
	}

	static function debugLocation(fn:HlFunction, index:Int):HlDebugLocation {
		if (fn.debugLocations.length == 0)
			return {
				path: "<generated>",
				line: 1,
				column: 1,
				endLine: 1,
				endColumn: 1,
				sourceHash: 0,
				start: null,
				end: null,
				flags: 1
			};
		return fn.debugLocations[index];
	}

	static function debugFilePaths(code:HlCode):Array<String> {
		var result:Array<String> = [], seen:Map<String, Bool> = [];
		var hasDebug = false;
		for (fn in code.functions)
			if (fn.debugLocations.length != 0)
				hasDebug = true;
		if (!hasDebug)
			return result;
		for (fn in code.functions) {
			if (fn.debugLocations.length == 0)
				addDebugFile(result, seen, "<generated>");
			else
				for (location in fn.debugLocations)
					addDebugFile(result, seen, location.path);
		}
		return result;
	}

	static function addDebugFile(result:Array<String>, seen:Map<String, Bool>, path:String):Void {
		if (!seen.exists(path)) {
			seen.set(path, true);
			result.push(path);
		}
	}

	static function writeOpcode(destination:RawPtr<runtime.hashlink.HlOpcode>, encoded:HlEncodedInstruction, generation:HlMetadataGeneration):Void {
		var operands = encoded.operands;
		destination.ref.op = cast encoded.opcode;
		destination.ref.p1 = cast operand(operands, 0);
		destination.ref.p2 = cast operand(operands, 1);
		destination.ref.p3 = cast operand(operands, 2);
		destination.ref.extra = RawPtr.nullPtr();
		switch encoded.opcode {
			case HlOpcode.Call2 | HlOpcode.EnumField:
				// HashLink stores the fourth fixed operand in the pointer field as an
				// immediate register/field index, not as an address.
				destination.ref.extra = immediatePointer(operands[3]);
			case HlOpcode.Call3:
				destination.ref.extra = copyOperands(generation, operands, 3, 2);
			case HlOpcode.Call4:
				destination.ref.extra = copyOperands(generation, operands, 3, 3);
			case HlOpcode.CallN | HlOpcode.CallMethod | HlOpcode.CallThis | HlOpcode.CallClosure | HlOpcode.MakeEnum:
				destination.ref.extra = copyOperands(generation, operands, 3, operands[2]);
			case HlOpcode.Switch:
				destination.ref.p3 = cast operands[operands[1] + 2];
				destination.ref.extra = copyOperands(generation, operands, 2, operands[1]);
			case _:
		}
	}

	static function operand(operands:Array<Int>, index:Int):Int
		return index < operands.length ? operands[index] : 0;

	static function copyOperands(generation:HlMetadataGeneration, operands:Array<Int>, start:Int, count:Int):RawPtr<Int32> {
		if (count == 0)
			return RawPtr.nullPtr();
		var result = generation.arena.allocInt32Array(count);
		for (index in 0...count)
			result.offset(index).store(cast operands[start + index]);
		return result;
	}

	static function immediatePointer(value:Int):RawPtr<Int32> {
		var pointer:RawPtr<Int32> = RawPtr.nullPtr();
		return pointer.byteOffset(value);
	}

	static function addNativeDescriptors(code:HlCode, generation:HlMetadataGeneration, types:Array<RawPtr<runtime.hashlink.HlType>>):Void {
		for (native in code.natives)
			generation.addNativeDescriptor({
				library: generation.stringPointer(native.library),
				name: generation.stringPointer(native.name),
				type: types[native.type],
				findex: native.functionIndex
			});
	}

	static function addConstants(code:HlCode, generation:HlMetadataGeneration):Void {
		for (constant in code.constants) {
			var fields:RawPtr<Int32> = constant.fields.length == 0 ? RawPtr.nullPtr() : generation.arena.allocInt32Array(constant.fields.length);
			for (index in 0...constant.fields.length)
				fields.offset(index).store(cast constant.fields[index]);
			generation.addConstant({
				global: constant.global,
				nfields: constant.fields.length,
				fields: fields
			});
		}
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
