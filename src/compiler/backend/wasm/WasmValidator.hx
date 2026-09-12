package compiler.backend.wasm;

import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmTypes.WasmRefType;
import compiler.backend.wasm.WasmTypes.WasmHeapType;
import compiler.backend.wasm.WasmTypes.WasmStorageType;
import compiler.backend.wasm.WasmTypes.WasmFieldType;
import compiler.backend.wasm.WasmTypes.WasmCompositeType;
import compiler.backend.wasm.WasmTypes.WasmTypeGroup;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmGlobal;

private typedef WasmControl = {
	final kind:Int;
	final result:Null<WasmValueType>;
	final height:Int;
}

/** Target-level structural validation before bytes reach an embedding runtime. */
class WasmValidator {
	public static function validate(module:WasmModule):Void {
		validateTypes(module);
		for (fn in module.functions)
			validateFunction(fn, [for (index in 0...module.functionCount()) module.functionType(index)], module.globals, module, module.tableMin,
				module.exceptionTagType);
		for (entry in module.exports)
			if (entry.functionIndex < 0 || entry.functionIndex >= module.functionCount())
				throw 'Wasm export "${entry.name}" references function ${entry.functionIndex}';
		var start = module.start;
		if (start != null) {
			if (start < 0 || start >= module.functionCount())
				throw 'Wasm start references function $start';
			var startType = module.functionType(start);
			if (startType.parameters.length != 0 || startType.results.length != 0)
				throw 'Wasm start function must have no parameters or results';
		}
	}

	static function validateTypes(module:WasmModule):Void {
		var typeCount = module.typeCount();
		for (index in 0...typeCount) {
			var subtype = module.typeAt(index),
				typeLimit = typeGroupEnd(module, index);
			if (subtype.supertypes.length > 1)
				throw 'Wasm type $index declares more than one supertype';
			for (supertype in subtype.supertypes)
				if (supertype < 0 || supertype >= typeCount)
					throw 'Wasm type $index references invalid supertype $supertype';
				else if (supertype >= index)
					throw 'Wasm type $index must reference an earlier supertype';
				else if (module.typeAt(supertype).finalType)
					throw 'Wasm type $index extends final type $supertype';
				else if (!isCompositeSubtype(subtype.composite, module.typeAt(supertype).composite, module))
					throw 'Wasm type $index is not a valid subtype of $supertype';
			switch subtype.composite {
				case Func(type):
					validateFunctionType(type, module, typeLimit);
				case Struct(fields):
					for (field in fields)
						validateStorageType(field.type, module, typeLimit);
				case Array(field):
					validateStorageType(field.type, module, typeLimit);
			}
		}
		for (index in 0...module.functionCount())
			validateFunctionType(module.functionType(index), module, typeCount);
		for (global in module.globals)
			validateValueType(global.type, module, typeCount);
	}

	static function typeGroupEnd(module:WasmModule, typeIndex:Int):Int {
		var current = 0;
		for (group in module.types) {
			var size = switch group {
				case WasmTypeGroup.Single(_): 1;
				case RecGroup(types): types.length;
			};
			if (typeIndex < current + size)
				return current + size;
			current += size;
		}
		throw 'Unknown Wasm type index $typeIndex';
	}

	static function validateFunctionType(type:WasmFunctionType, module:WasmModule, typeLimit:Int):Void {
		for (parameter in type.parameters)
			validateValueType(parameter, module, typeLimit);
		for (result in type.results)
			validateValueType(result, module, typeLimit);
	}

	static function validateStorageType(type:WasmStorageType, module:WasmModule, typeLimit:Int):Void {
		switch type {
			case Value(value):
				validateValueType(value, module, typeLimit);
			case I8, I16:
		}
	}

	static function validateValueType(type:WasmValueType, module:WasmModule, typeLimit:Int):Void {
		switch type {
			case Ref(refType):
				validateHeapType(refType.heap, module, typeLimit);
			default:
		}
	}

	static function validateHeapType(type:WasmHeapType, module:WasmModule, typeLimit:Int):Void {
		switch type {
			case Type(index):
				if (index < 0 || index >= typeLimit)
					throw 'Wasm reference uses invalid heap type index $index';
			default:
		}
	}

	static function validateFunction(fn:WasmFunction, functions:Array<WasmFunctionType>, globals:Array<WasmGlobal>, module:WasmModule, tableMin:Null<Int>,
			tagType:Null<Int>):Void {
		var labels:Array<Bool> = [],
			localCount = fn.type.parameters.length + fn.locals.length;
		for (result in fn.type.results)
			validateValueType(result, module, module.typeCount());
		for (local in fn.locals)
			validateValueType(local.type, module, module.typeCount());
		for (instruction in fn.body) {
			switch instruction {
				case Block(result), Loop(result), Try(result):
					if (result != null)
						validateValueType(result, module, module.typeCount());
					labels.push(false);
				case If(result):
					if (result != null)
						validateValueType(result, module, module.typeCount());
					labels.push(true);
				case Else:
					if (labels.length == 0 || !labels[labels.length - 1])
						throw 'Wasm function ${fn.name} has an else without an if';
				case Catch(tag):
					if (tagType == null || tag != 0)
						throw 'Wasm function ${fn.name} references an invalid exception tag $tag';
				case End:
					if (labels.length == 0)
						throw 'Wasm function ${fn.name} has an unmatched end';
					labels.pop();
				case Br(depth), BrIf(depth):
					if (depth < 0 || depth >= labels.length)
						throw 'Wasm function ${fn.name} has an invalid branch depth $depth';
				case BrTable(targets, defaultDepth):
					for (depth in targets)
						validateDepth(fn, depth, labels.length);
					validateDepth(fn, defaultDepth, labels.length);
				case LocalGet(index), LocalSet(index), LocalTee(index):
					if (index < 0 || index >= localCount)
						throw 'Wasm function ${fn.name} references invalid local $index';
				case Call(index):
					if (index < 0 || index >= functions.length)
						throw 'Wasm function ${fn.name} references invalid function $index';
				case CallIndirect(typeIndex):
					if (tableMin == null)
						throw 'Wasm function ${fn.name} uses call_indirect without a table';
					if (typeIndex < 0 || typeIndex >= module.typeCount())
						throw 'Wasm function ${fn.name} references invalid indirect type $typeIndex';
					module.functionTypeAt(typeIndex);
				case GlobalGet(index), GlobalSet(index):
					if (index < 0 || index >= globals.length)
						throw 'Wasm function ${fn.name} references invalid global $index';
				case RefNull(heapType):
					validateHeapType(heapType, module, module.typeCount());
				case RefTest(type), RefCast(type):
					validateHeapType(type.heap, module, module.typeCount());
				case StructNew(typeIndex), StructNewDefault(typeIndex), StructGet(typeIndex, _), StructGetSigned(typeIndex, _),
					StructGetUnsigned(typeIndex, _), StructSet(typeIndex, _):
					structType(module, typeIndex);
					switch instruction {
						case StructGet(_, fieldIndex), StructGetSigned(_, fieldIndex), StructGetUnsigned(_, fieldIndex), StructSet(_, fieldIndex):
							structField(module, typeIndex, fieldIndex);
						default:
					}
				case ArrayNew(typeIndex), ArrayNewDefault(typeIndex), ArrayGet(typeIndex), ArrayGetSigned(typeIndex), ArrayGetUnsigned(typeIndex),
					ArraySet(typeIndex):
					arrayType(module, typeIndex);
				case ArrayCopy(destinationTypeIndex, sourceTypeIndex):
					arrayType(module, destinationTypeIndex);
					arrayType(module, sourceTypeIndex);
				default:
			}
		}
		if (labels.length != 0)
			throw 'Wasm function ${fn.name} has ${labels.length} unclosed control blocks';
		validateStack(fn, functions, globals, module, tagType);
	}

	static function validateStack(fn:WasmFunction, functions:Array<WasmFunctionType>, globals:Array<WasmGlobal>, module:WasmModule, tagType:Null<Int>):Void {
		var locals:Array<WasmValueType> = fn.type.parameters.copy();
		for (local in fn.locals)
			locals.push(local.type);
		var stack:Array<WasmValueType> = [],
			controls:Array<WasmControl> = [],
			reachable = true;
		for (instruction in fn.body) {
			switch instruction {
				case Unreachable:
					reachable = false;
				case Block(result):
					controls.push({kind: 0, result: result, height: stack.length});
				case Loop(result):
					controls.push({kind: 1, result: result, height: stack.length});
				case Try(result):
					controls.push({kind: 3, result: result, height: stack.length});
				case If(result):
					pop(stack, I32, fn);
					controls.push({kind: 2, result: result, height: stack.length});
				case Else:
					if (controls.length == 0 || controls[controls.length - 1].kind != 2)
						throw 'Wasm function ${fn.name} has an invalid else frame';
					var frame = controls[controls.length - 1];
					reset(stack, frame.height, frame.result, reachable, fn, module, false);
					reachable = true;
				case Catch(tag):
					if (tagType == null)
						throw 'Wasm function ${fn.name} references an invalid exception tag $tag';
					if (controls.length == 0 || controls[controls.length - 1].kind != 3)
						throw 'Wasm function ${fn.name} has a catch without a try';
					var catchFrame = controls[controls.length - 1];
					reset(stack, catchFrame.height, catchFrame.result, reachable, fn, module, false);
					stack.push(I32);
					reachable = true;
				case End:
					if (controls.length == 0)
						continue;
					var frame = controls.pop();
					reset(stack, frame.height, frame.result, reachable, fn, module, true);
					reachable = true;
				case Br(depth):
					validateBranch(controls, depth, fn);
					reachable = false;
				case BrIf(depth):
					pop(stack, I32, fn);
					validateBranch(controls, depth, fn);
				case BrTable(targets, defaultDepth):
					pop(stack, I32, fn);
					for (depth in targets)
						validateBranch(controls, depth, fn);
					validateBranch(controls, defaultDepth, fn);
					reachable = false;
				case Return:
					for (index in 0...fn.type.results.length)
						pop(stack, fn.type.results[fn.type.results.length - index - 1], fn, module);
					reachable = false;
				case Throw(tag):
					if (tagType == null || tag != 0)
						throw 'Wasm function ${fn.name} references an invalid exception tag $tag';
					pop(stack, I32, fn);
					reachable = false;
				case Call(index):
					var type = functions[index];
					for (index in 0...type.parameters.length)
						pop(stack, type.parameters[type.parameters.length - index - 1], fn, module);
					for (result in type.results)
						stack.push(result);
				case CallIndirect(typeIndex):
					var type = module.functionTypeAt(typeIndex);
					pop(stack, I32, fn);
					for (index in 0...type.parameters.length)
						pop(stack, type.parameters[type.parameters.length - index - 1], fn, module);
					for (result in type.results)
						stack.push(result);
				case Drop:
					if (reachable)
						popAny(stack, fn);
				case MemoryCopy:
					if (reachable) {
						pop(stack, I32, fn);
						pop(stack, I32, fn);
						pop(stack, I32, fn);
					}
				case MemoryFill:
					if (reachable) {
						pop(stack, I32, fn);
						pop(stack, I32, fn);
						pop(stack, I32, fn);
					}
				case MemorySize:
					if (reachable)
						stack.push(I32);
				case MemoryGrow:
					if (reachable) {
						pop(stack, I32, fn);
						stack.push(I32);
					}
				case LocalGet(index):
					if (reachable)
						stack.push(locals[index]);
				case LocalSet(index):
					if (reachable) {
						var actual = popAny(stack, fn);
						if (!isValueSubtype(actual, locals[index], module))
							throw 'Wasm function ${fn.name} local $index expects ${locals[index]}, got $actual';
					}
				case LocalTee(index):
					if (reachable) {
						pop(stack, locals[index], fn, module);
						stack.push(locals[index]);
					}
				case GlobalGet(index):
					if (reachable)
						stack.push(globals[index].type);
				case GlobalSet(index):
					if (reachable)
						pop(stack, globals[index].type, fn, module);
				case I32Load(_), I32Load8S(_), I32Load8U(_), I32Load16S(_), I32Load16U(_):
					if (reachable) {
						pop(stack, I32, fn);
						stack.push(I32);
					}
				case I64Load(_):
					if (reachable) {
						pop(stack, I32, fn);
						stack.push(I64);
					}
				case F32Load(_):
					if (reachable) {
						pop(stack, I32, fn);
						stack.push(F32);
					}
				case F64Load(_):
					if (reachable) {
						pop(stack, I32, fn);
						stack.push(F64);
					}
				case I32Store(_), I32Store8(_), I32Store16(_):
					if (reachable) {
						pop(stack, I32, fn);
						pop(stack, I32, fn);
					}
				case I64Store(_):
					if (reachable) {
						pop(stack, I64, fn);
						pop(stack, I32, fn);
					}
				case F32Store(_):
					if (reachable) {
						pop(stack, F32, fn);
						pop(stack, I32, fn);
					}
				case F64Store(_):
					if (reachable) {
						pop(stack, F64, fn);
						pop(stack, I32, fn);
					}
				case I32Const(_):
					if (reachable)
						stack.push(I32);
				case I64Const(_):
					if (reachable)
						stack.push(I64);
				case F64Const(_):
					if (reachable)
						stack.push(F64);
				case I32Add, I32Sub, I32Mul, I32DivS, I32RemS, I32And, I32Xor, I32Or, I32Shl, I32ShrS, I32ShrU, I32Eq, I32LtS, I32LeS:
					binary(stack, I32, I32, fn);
				case I64Add, I64Sub, I64Mul, I64DivS, I64RemS, I64And, I64Xor, I64Or, I64Shl, I64ShrS, I64ShrU:
					binary(stack, I64, I64, fn);
				case I64Eq, I64LtS, I64LtU, I64LeS:
					binary(stack, I64, I32, fn);
				case F64Add, F64Sub, F64Mul, F64Div:
					binary(stack, F64, F64, fn);
				case F64Eq, F64Lt, F64Le:
					binary(stack, F64, I32, fn);
				case I32Eqz:
					pop(stack, I32, fn);
					if (reachable)
						stack.push(I32);
				case I64Eqz:
					pop(stack, I64, fn);
					if (reachable)
						stack.push(I32);
				case F64ConvertI32S:
					pop(stack, I32, fn);
					if (reachable)
						stack.push(F64);
				case F64ConvertI64S:
					pop(stack, I64, fn);
					if (reachable)
						stack.push(F64);
				case I64ExtendI32S, I64ExtendI32U:
					pop(stack, I32, fn);
					if (reachable)
						stack.push(I64);
				case F64PromoteF32:
					pop(stack, F32, fn);
					if (reachable)
						stack.push(F64);
				case F32DemoteF64:
					pop(stack, F64, fn);
					if (reachable)
						stack.push(F32);
				case I32WrapI64:
					pop(stack, I64, fn);
					if (reachable)
						stack.push(I32);
				case I32TruncF64S:
					pop(stack, F64, fn);
					if (reachable)
						stack.push(I32);
				case I64ReinterpretF64:
					pop(stack, F64, fn);
					if (reachable)
						stack.push(I64);
				case RefNull(heapType):
					if (reachable)
						stack.push(Ref({nullable: true, heap: heapType}));
				case RefIsNull:
					if (reachable) {
						popReference(stack, fn);
						stack.push(I32);
					}
				case RefEq:
					if (reachable) {
						var right = popReference(stack, fn),
							left = popReference(stack, fn);
						if (!isHeapSubtype(left.heap, Eq, module) || !isHeapSubtype(right.heap, Eq, module))
							throw 'Wasm function ${fn.name} uses ref.eq with a non-equatable reference';
						stack.push(I32);
					}
				case RefTest(_):
					if (reachable) {
						popReference(stack, fn);
						stack.push(I32);
					}
				case RefCast(type):
					if (reachable) {
						popReference(stack, fn);
						stack.push(Ref(type));
					}
				case StructNew(typeIndex):
					var fields = structType(module, typeIndex);
					if (reachable) {
						for (index in 0...fields.length)
							pop(stack, storageValue(fields[fields.length - index - 1].type), fn, module);
						stack.push(nonNullTypeRef(typeIndex));
					}
				case StructNewDefault(typeIndex):
					for (field in structType(module, typeIndex))
						if (!isDefaultable(field.type))
							throw 'Wasm function ${fn.name} uses struct.new_default with a non-defaultable field';
					if (reachable)
						stack.push(nonNullTypeRef(typeIndex));
				case StructGet(typeIndex, fieldIndex):
					var field = structField(module, typeIndex, fieldIndex);
					if (reachable) {
						popTypedReference(stack, typeIndex, fn, module);
						stack.push(unpackedValue(field.type, 0, fn));
					}
				case StructGetSigned(typeIndex, fieldIndex):
					var field = structField(module, typeIndex, fieldIndex);
					if (reachable) {
						popTypedReference(stack, typeIndex, fn, module);
						stack.push(unpackedValue(field.type, 1, fn));
					}
				case StructGetUnsigned(typeIndex, fieldIndex):
					var field = structField(module, typeIndex, fieldIndex);
					if (reachable) {
						popTypedReference(stack, typeIndex, fn, module);
						stack.push(unpackedValue(field.type, 2, fn));
					}
				case StructSet(typeIndex, fieldIndex):
					var field = structField(module, typeIndex, fieldIndex);
					if (!field.mutable)
						throw 'Wasm function ${fn.name} writes an immutable struct field';
					if (reachable) {
						pop(stack, storageValue(field.type), fn, module);
						popTypedReference(stack, typeIndex, fn, module);
					}
				case ArrayNew(typeIndex):
					var field = arrayType(module, typeIndex);
					if (reachable) {
						pop(stack, I32, fn);
						pop(stack, storageValue(field.type), fn, module);
						stack.push(nonNullTypeRef(typeIndex));
					}
				case ArrayNewDefault(typeIndex):
					var field = arrayType(module, typeIndex);
					if (!isDefaultable(field.type))
						throw 'Wasm function ${fn.name} uses array.new_default with a non-defaultable element type';
					if (reachable) {
						pop(stack, I32, fn);
						stack.push(nonNullTypeRef(typeIndex));
					}
				case ArrayGet(typeIndex):
					var field = arrayType(module, typeIndex);
					if (reachable) {
						pop(stack, I32, fn);
						popTypedReference(stack, typeIndex, fn, module);
						stack.push(unpackedValue(field.type, 0, fn));
					}
				case ArrayGetSigned(typeIndex):
					var field = arrayType(module, typeIndex);
					if (reachable) {
						pop(stack, I32, fn);
						popTypedReference(stack, typeIndex, fn, module);
						stack.push(unpackedValue(field.type, 1, fn));
					}
				case ArrayGetUnsigned(typeIndex):
					var field = arrayType(module, typeIndex);
					if (reachable) {
						pop(stack, I32, fn);
						popTypedReference(stack, typeIndex, fn, module);
						stack.push(unpackedValue(field.type, 2, fn));
					}
				case ArraySet(typeIndex):
					var field = arrayType(module, typeIndex);
					if (!field.mutable)
						throw 'Wasm function ${fn.name} writes an immutable array element';
					if (reachable) {
						pop(stack, storageValue(field.type), fn, module);
						pop(stack, I32, fn);
						popTypedReference(stack, typeIndex, fn, module);
					}
				case ArrayLen:
					if (reachable) {
						var reference = popReference(stack, fn);
						if (!isArrayReference(reference, module))
							throw 'Wasm function ${fn.name} uses array.len with a non-array reference';
						stack.push(I32);
					}
				case ArrayCopy(destinationTypeIndex, sourceTypeIndex):
					var destination = arrayType(module, destinationTypeIndex),
						source = arrayType(module, sourceTypeIndex);
					if (!destination.mutable || !isStorageSubtype(source.type, destination.type, module))
						throw 'Wasm function ${fn.name} uses array.copy with incompatible array element types';
					if (reachable) {
						pop(stack, I32, fn);
						pop(stack, I32, fn);
						popTypedReference(stack, sourceTypeIndex, fn, module);
						pop(stack, I32, fn);
						popTypedReference(stack, destinationTypeIndex, fn, module);
					}
				case Nop:
			}
		}
		if (controls.length != 0)
			throw 'Wasm function ${fn.name} has unclosed stack control frames';
		if (reachable) {
			if (stack.length != fn.type.results.length)
				throw 'Wasm function ${fn.name} leaves ${stack.length} stack values for ${fn.type.results.length} results';
			for (index in 0...fn.type.results.length)
				pop(stack, fn.type.results[fn.type.results.length - index - 1], fn, module);
		}
	}

	static function binary(stack:Array<WasmValueType>, input:WasmValueType, output:WasmValueType, fn:WasmFunction):Void {
		pop(stack, input, fn);
		pop(stack, input, fn);
		stack.push(output);
	}

	static function structType(module:WasmModule, typeIndex:Int):Array<WasmFieldType> {
		if (typeIndex < 0 || typeIndex >= module.typeCount())
			throw 'Wasm instruction references invalid struct type $typeIndex';
		return switch module.typeAt(typeIndex).composite {
			case Struct(fields): fields;
			default: throw 'Wasm type $typeIndex is not a struct type';
		};
	}

	static function structField(module:WasmModule, typeIndex:Int, fieldIndex:Int):WasmFieldType {
		var fields = structType(module, typeIndex);
		if (fieldIndex < 0 || fieldIndex >= fields.length)
			throw 'Wasm struct type $typeIndex has no field $fieldIndex';
		return fields[fieldIndex];
	}

	static function arrayType(module:WasmModule, typeIndex:Int):WasmFieldType {
		if (typeIndex < 0 || typeIndex >= module.typeCount())
			throw 'Wasm instruction references invalid array type $typeIndex';
		return switch module.typeAt(typeIndex).composite {
			case Array(field): field;
			default: throw 'Wasm type $typeIndex is not an array type';
		};
	}

	static function storageValue(type:WasmStorageType):WasmValueType
		return switch type {
			case Value(value): value;
			case I8, I16: I32;
		};

	static function unpackedValue(type:WasmStorageType, mode:Int, fn:WasmFunction):WasmValueType {
		return switch type {
			case Value(value) if (mode == 0): value;
			case I8 if (mode == 1 || mode == 2): I32;
			case I16 if (mode == 1 || mode == 2): I32;
			case I8, I16:
				throw 'Wasm function ${fn.name} uses a packed-field access with the wrong signedness';
			case Value(_):
				throw 'Wasm function ${fn.name} uses a packed-field access on an unpacked field';
		};
	}

	static function isDefaultable(type:WasmStorageType):Bool
		return switch type {
			case I8, I16: true;
			case Value(I32), Value(I64), Value(F32), Value(F64): true;
			case Value(Ref(refType)): refType.nullable;
		};

	static function isStorageSubtype(actual:WasmStorageType, expected:WasmStorageType, module:WasmModule):Bool {
		return switch [actual, expected] {
			case [I8, I8], [I16, I16]: true;
			case [Value(actualType), Value(expectedType)]: isValueSubtype(actualType, expectedType, module);
			default: false;
		};
	}

	static function isCompositeSubtype(actual:WasmCompositeType, expected:WasmCompositeType, module:WasmModule):Bool {
		return switch [actual, expected] {
			case [Struct(actualFields), Struct(expectedFields)]:
				if (actualFields.length < expectedFields.length) false; else {
					var matches = true;
					for (index in 0...expectedFields.length)
						if (!isFieldSubtype(actualFields[index], expectedFields[index], module))
							matches = false;
					matches;
				}
			case [Array(actualField), Array(expectedField)]: isFieldSubtype(actualField, expectedField, module);
			case [Func(actualType), Func(expectedType)]:
				actualType.parameters.length == expectedType.parameters.length
				&& actualType.results.length == expectedType.results.length
				&& resultTypesSubtype(expectedType.parameters, actualType.parameters, module)
				&& resultTypesSubtype(actualType.results, expectedType.results, module);
			default: false;
		};
	}

	static function resultTypesSubtype(actual:Array<WasmValueType>, expected:Array<WasmValueType>, module:WasmModule):Bool {
		if (actual.length != expected.length)
			return false;
		for (index in 0...actual.length)
			if (!isValueSubtype(actual[index], expected[index], module))
				return false;
		return true;
	}

	static function isFieldSubtype(actual:WasmFieldType, expected:WasmFieldType, module:WasmModule):Bool {
		return isStorageSubtype(actual.type, expected.type, module)
			&& (!actual.mutable || !expected.mutable || isStorageSubtype(expected.type, actual.type, module));
	}

	static function nonNullTypeRef(typeIndex:Int):WasmValueType
		return Ref({nullable: false, heap: Type(typeIndex)});

	static function popReference(stack:Array<WasmValueType>, fn:WasmFunction):WasmRefType {
		return switch popAny(stack, fn) {
			case Ref(type): type;
			default: throw 'Wasm function ${fn.name} expected a reference on the value stack';
		};
	}

	static function popTypedReference(stack:Array<WasmValueType>, typeIndex:Int, fn:WasmFunction, module:WasmModule):Void {
		var type = popReference(stack, fn);
		if (!isHeapSubtype(type.heap, Type(typeIndex), module))
			throw 'Wasm function ${fn.name} expected a reference to heap type $typeIndex, got $type';
	}

	static function isArrayReference(type:WasmRefType, module:WasmModule):Bool {
		return isHeapSubtype(type.heap, Array, module);
	}

	static function pop(stack:Array<WasmValueType>, expected:WasmValueType, fn:WasmFunction, ?module:WasmModule):Void {
		var actual = popAny(stack, fn);
		if (module == null ? !sameValueType(actual, expected) : !isValueSubtype(actual, expected, module))
			throw 'Wasm function ${fn.name} expected $expected on the value stack, got $actual';
	}

	static function isValueSubtype(actual:WasmValueType, expected:WasmValueType, module:WasmModule):Bool {
		return switch [actual, expected] {
			case [I32, I32], [I64, I64], [F32, F32], [F64, F64]: true;
			case [Ref(actualType), Ref(expectedType)]: (!actualType.nullable || expectedType.nullable) && isHeapSubtype(actualType.heap, expectedType.heap,
					module);
			default: false;
		};
	}

	static function isHeapSubtype(actual:WasmHeapType, expected:WasmHeapType, module:WasmModule):Bool {
		if (sameHeapType(actual, expected))
			return true;
		return switch actual {
			case Type(index) if (index >= 0 && index < module.typeCount()):
				switch expected {
					case Type(superIndex) if (superIndex >= 0 && superIndex < module.typeCount()):
						isTypeSubtype(index, superIndex, module, []);
					case Any, Eq, I31, Struct, Array, Func, Extern, None, NoExtern, NoFunc, Exn, NoExn:
						var root:WasmHeapType = switch module.typeAt(index).composite {
							case WasmCompositeType.Func(_): WasmHeapType.Func;
							case WasmCompositeType.Struct(_): WasmHeapType.Struct;
							case WasmCompositeType.Array(_): WasmHeapType.Array;
						};
						isHeapSubtype(root, expected, module);
					default: false;
				};
			case I31: expected == Eq || expected == Any;
			case Struct, Array: expected == Eq || expected == Any;
			case Eq: expected == Any;
			case None: expected == Any || expected == Eq || expected == I31 || expected == Struct || expected == Array;
			case NoFunc: expected == Func;
			case NoExtern: expected == Extern;
			case NoExn: expected == Exn;
			default: false;
		};
	}

	static function isTypeSubtype(actual:Int, expected:Int, module:WasmModule, seen:Array<Int>):Bool {
		if (actual == expected)
			return true;
		if (seen.indexOf(actual) >= 0)
			return false;
		seen.push(actual);
		for (supertype in module.typeAt(actual).supertypes)
			if (isTypeSubtype(supertype, expected, module, seen))
				return true;
		return false;
	}

	static function sameValueType(left:WasmValueType, right:WasmValueType):Bool
		return switch [left, right] {
			case [I32, I32], [I64, I64], [F32, F32], [F64, F64]: true;
			case [Ref(leftType), Ref(rightType)]: (!leftType.nullable || rightType.nullable) && sameHeapType(leftType.heap, rightType.heap);
			default: false;
		};

	static function sameHeapType(left:WasmHeapType, right:WasmHeapType):Bool {
		return switch [left, right] {
			case [Any, Any], [Eq, Eq], [I31, I31], [Struct, Struct], [Array, Array], [Func, Func], [Extern, Extern], [None, None], [NoExtern, NoExtern],
				[NoFunc, NoFunc], [Exn, Exn], [NoExn, NoExn]: true;
			case [Type(leftIndex), Type(rightIndex)]: leftIndex == rightIndex;
			default: false;
		};
	}

	static function popAny(stack:Array<WasmValueType>, fn:WasmFunction):WasmValueType {
		if (stack.length == 0)
			throw 'Wasm function ${fn.name} underflowed the value stack';
		return stack.pop();
	}

	static function reset(stack:Array<WasmValueType>, height:Int, result:Null<WasmValueType>, reachable:Bool, fn:WasmFunction, module:WasmModule,
			emitResult:Bool):Void {
		if (reachable) {
			var resultCount = result == null ? 0 : 1;
			if (stack.length < height + resultCount)
				throw 'Wasm function ${fn.name} ended a control frame with too few values';
			if (stack.length > height + resultCount)
				throw 'Wasm function ${fn.name} ended a control frame with too many values (${stack.length}, expected ${height + resultCount})';
			if (result != null && !isValueSubtype(stack[height], result, module))
				throw 'Wasm function ${fn.name} ended a control frame with an incompatible result type';
		}
		while (stack.length > height)
			stack.pop();
		if (reachable && emitResult)
			switch result {
				case null:
				default:
					stack.push(result);
			}
	}

	static function validateBranch(controls:Array<WasmControl>, depth:Int, fn:WasmFunction):Void {
		if (depth < 0 || depth >= controls.length)
			throw 'Wasm function ${fn.name} branches to invalid stack depth $depth';
	}

	static function validateDepth(fn:WasmFunction, depth:Int, labelCount:Int):Void
		if (depth < 0 || depth >= labelCount)
			throw 'Wasm function ${fn.name} has an invalid branch-table depth $depth';
}
