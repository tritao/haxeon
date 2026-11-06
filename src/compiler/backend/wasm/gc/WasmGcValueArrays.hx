package compiler.backend.wasm.gc;

import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrType;
import compiler.ir.IrValueLaneReference;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmLocal;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmModuleSupport;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;

/** Runtime operations over the GC value-array wrapper and its scalar/reference lanes. */
class WasmGcValueArrays {
	public static function supports(symbol:String):Bool return switch symbol {
		case "__value_array_alloc", "__value_array_set_bridge", "__value_array_retype", "__value_array_read_ref", "__value_array_write_ref", "__value_array_clear_ref": true;
		case "__value_array_read_i32", "__value_array_read_i64", "__value_array_read_bool", "__value_array_read_f32", "__value_array_read_f64",
			"__value_array_write_i32", "__value_array_write_i64", "__value_array_write_bool", "__value_array_write_f32", "__value_array_write_f64",
			"__value_array_read_ptr", "__value_array_write_ptr", "__value_array_read_type", "__value_array_write_type",
			"__value_array_read_callback", "__value_array_write_callback",
			"__value_array_clear_scalar", "__value_array_clear", "__value_array_ensure", "__value_array_resize", "__value_array_insert_empty", "__value_array_reverse",
			"__value_array_copy", "__value_array_slice", "__value_array_concat", "__value_array_splice", "__value_array_remove_at", "__value_array_is_initialized", "__value_array_validate", "__value_array_mark": true;
		default: false;
	};

	public static function register(module:WasmModule, functions:Map<String, Int>, plan:WasmGcTypePlan, program:IrProgram, used:Map<String, Bool>,
			?accessors:Map<String, WasmGcValueArrayAccessors.WasmGcValueArrayScalarAccess>):Void {
		if (accessors == null) accessors = [];
		var throws = WasmModuleSupport.hasExceptions(program), dynamicStore = false, dynamicInsert = false;
		WasmGcLaneStorage.register(module, functions, plan, program);
		for (native in program.natives) if (used.exists(native.name) && compiler.backend.wasm.WasmValueLaneRuntime.isLinked(functions)) {
			if (native.name == "__array_set_any" || native.name == "__array_push_any") dynamicStore = true;
			if (native.name == "__array_insert_any" || native.name == "__array_unshift_any") dynamicInsert = true;
		}
		if (dynamicStore || dynamicInsert) {
			var writeSignature = module.typeIndex(plan.wasmFunctionType([Array(Dyn),I32,Dyn], Void)),
				newLikeIndex = WasmModuleSupport.requiredFunctionIndex(functions,"$lane-storage:new-like"),
				moveIndex = WasmModuleSupport.requiredFunctionIndex(functions,"$lane-runtime:move"),
				ensureIndex = WasmModuleSupport.requiredFunctionIndex(functions,"$lane-runtime:ensure"),
				insertIndex = WasmModuleSupport.requiredFunctionIndex(functions,"$lane-runtime:insert");
			if (dynamicStore) functions.set("$value-array:runtime:store-value", module.addFunction(dynamicWrite(plan, throws, newLikeIndex, moveIndex, ensureIndex, -1, writeSignature)));
			if (dynamicInsert) functions.set("$value-array:runtime:insert-value", module.addFunction(dynamicWrite(plan, throws, newLikeIndex, moveIndex, ensureIndex, insertIndex, writeSignature)));
		}
		var retypeAllocator = -1;
		for (native in program.natives) if (used.exists(native.name) && native.symbol == "__value_array_retype") {
			var allocator:IrNative = {name:"$value-array:internal:retype-allocate", library:"haxeon_runtime", symbol:"__value_array_alloc", arguments:[I32,TypeRef,I32,I32,I32,Bool], result:Array(Dyn)};
			retypeAllocator = module.addFunction(allocate(plan, allocator, throws)); break;
		}
		for (native in program.natives) if (used.exists(native.name) && supports(native.symbol)) {
			if (compiler.backend.wasm.WasmValueLaneRuntime.bind(functions, native)) continue;
			if (plan.valueArrayWrapperTypeIndex < 0) throw "Missing Wasm GC value-array type plan";
			var fn = switch native.symbol {
				case "__value_array_alloc": allocate(plan, native, throws);
				case "__value_array_set_bridge": setBridge(plan, native, throws);
				case "__value_array_retype": retype(module, plan, native, throws, retypeAllocator);
				case "__value_array_read_ref": referenceSlot(plan, native, throws, false, false);
				case "__value_array_write_ref": referenceSlot(plan, native, throws, true, false);
				case "__value_array_clear_ref": referenceSlot(plan, native, throws, true, true);
				case "__value_array_is_initialized", "__value_array_validate", "__value_array_mark": validityOperation(plan, native, throws);
				case "__value_array_read_i32", "__value_array_read_i64", "__value_array_read_bool", "__value_array_read_f32", "__value_array_read_f64",
					"__value_array_write_i32", "__value_array_write_i64", "__value_array_write_bool", "__value_array_write_f32", "__value_array_write_f64",
					"__value_array_read_ptr", "__value_array_write_ptr", "__value_array_read_type", "__value_array_write_type",
					"__value_array_read_callback", "__value_array_write_callback",
					"__value_array_clear_scalar": WasmGcScalarArrayAccess.build(plan, native, throws, accessors.get(native.name));
				default: throw 'Unknown Wasm GC value-array native ${native.symbol}';
			};
			if (native.symbol != "__value_array_alloc" && native.symbol != "__value_array_retype") {
				var prefix = resolveForward(plan, 0);
				if (native.symbol == "__value_array_concat") prefix = prefix.concat(resolveForward(plan, 1));
				for (index in 0...prefix.length) fn.body.insert(index, prefix[index]);
			}
			functions.set(native.name, module.addFunction(fn));
		}
	}

	public static function failure(throws:Bool):Array<WasmInstruction> return throws ? [RefNull(Any), Throw(0)] : [Unreachable];

	static function field(wrapper:Int, index:Int):Array<WasmInstruction>
		return [LocalGet(0), RefCast({nullable:false, heap:Type(wrapper)}), StructGet(wrapper, index)];
	static function fieldAt(wrapper:Int, index:Int, array:Int):Array<WasmInstruction>
		return [LocalGet(array), RefCast({nullable:false, heap:Type(wrapper)}), StructGet(wrapper, index)];

	/** Resolve only forwarding headers; ordinary arrays and direct inline wrappers are left unchanged. */
	public static function resolveForward(plan:WasmGcTypePlan, array:Int):Array<WasmInstruction> {
		var wrapper = plan.valueArrayWrapperTypeIndex, base = plan.arrayType(plan.arrayElementTypes()[0]), marker = plan.valueArrayForwardLaneTypeIndex;
		return [LocalGet(array), RefIsNull, I32Eqz, LocalGet(array), RefTest({nullable:false, heap:Type(wrapper)}), I32Eqz, I32And, If(null),
			LocalGet(array), StructGet(base, WasmGcTypePlan.arrayDataFieldIndex()), RefTest({nullable:false, heap:Type(marker)}), If(null),
			LocalGet(array), StructGet(base, WasmGcTypePlan.arrayDataFieldIndex()), RefCast({nullable:false, heap:Type(marker)}), I32Const(0),
			ArrayGet(marker), RefCast({nullable:false, heap:Type(wrapper)}), LocalSet(array), End, End];
	}

	/** Length is the only mutable wrapper field read without going through the value-array runtime. */
	public static function syncForwardLength(plan:WasmGcTypePlan):Array<WasmInstruction> {
		var w = plan.valueArrayWrapperTypeIndex, base = plan.arrayType(plan.arrayElementTypes()[0]);
		return field(w, WasmGcTypePlan.VALUE_ARRAY_FORWARD_HEADER_FIELD).concat([RefIsNull, I32Eqz, If(null)])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_FORWARD_HEADER_FIELD)).concat([RefCast({nullable:false, heap:Type(base)})])
			.concat(field(w, WasmGcTypePlan.arrayLengthFieldIndex())).concat([StructSet(base, WasmGcTypePlan.arrayLengthFieldIndex()), End]);
	}

	/** A checked view of an already-inline array retains the original wrapper and checks its complete layout. */
	static function retype(module:WasmModule, plan:WasmGcTypePlan, native:IrNative, throws:Bool, allocator:Int):WasmFunction {
		if (native.arguments.length != 9 || allocator < 0) throw "Invalid Wasm GC value-array retype";
		var w = plan.valueArrayWrapperTypeIndex, base = plan.arrayType(plan.arrayElementTypes()[0]), marker = plan.valueArrayForwardLaneTypeIndex,
			storage = plan.arrayStorageType(Dyn), index = 9, length = 10, candidate = 11, forward = 12, item = 13, resolved = 14,
			sourceType = 15, readKind = 16,
			acceptSignature = module.typeIndex(plan.wasmFunctionType([Dyn], Bool)), writeSignature = module.typeIndex(plan.wasmFunctionType([Array(Dyn),I32,Dyn], Void));
		var enumStorage:Array<{id:Int, storage:Int}> = [];
		for (element in plan.arrayElementTypes()) switch element {
			case Enum(name):
				for (declaration in plan.program.enums) if (declaration.name == name && declaration.inlineStorage != null)
					enumStorage.push({id:plan.runtimeTypeIds.id(element), storage:plan.arrayStorageType(element)});
			default:
		}
		function backing(storageType:Int, read:Bool):Array<WasmInstruction> {
			var instructions = fieldAt(base, WasmGcTypePlan.arrayDataFieldIndex(), 0);
			return read ? instructions.concat([RefCast({nullable:false, heap:Type(storageType)}), LocalGet(index), ArrayGet(storageType), LocalSet(item)])
				: instructions.concat([RefTest({nullable:false, heap:Type(storageType)}), I32Eqz, If(null)]).concat(failure(throws)).concat([End]);
		}
		function sourceElement(read:Bool):Array<WasmInstruction> {
			var instructions = backing(storage, read);
			for (offset in 0...enumStorage.length) {
				var entry = enumStorage[offset];
				instructions = [LocalGet(readKind), I32Const(offset + 1), I32Eq, If(null)]
					.concat(backing(entry.storage, read)).concat([Else]).concat(instructions).concat([End]);
			}
			return instructions;
		}
		var body:Array<WasmInstruction> = [LocalGet(0), RefIsNull, If(null), LocalGet(0), Return, End, LocalGet(0), LocalSet(resolved)]
			.concat(resolveForward(plan, resolved)).concat([LocalGet(resolved), RefTest({nullable:false, heap:Type(w)}), If(null)]);
		for (pair in [{field:WasmGcTypePlan.arrayElementTypeFieldIndex(), arg:1}, {field:WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD, arg:2},
				{field:WasmGcTypePlan.VALUE_ARRAY_REFERENCE_STRIDE_FIELD, arg:3}, {field:WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD, arg:4},
				{field:WasmGcTypePlan.VALUE_ARRAY_VALIDITY_FIELD, arg:5}])
			body = body.concat(fieldAt(w, pair.field, resolved)).concat([LocalGet(pair.arg), I32Eq, I32Eqz, If(null)]).concat(failure(throws)).concat([End]);
		body = body.concat([LocalGet(0), Return, End]);
		// Native enum arrays already contain Dynamic-header-bearing values in enum-typed reference storage.
		// Validate both the logical element and the actual GC array type before reading or changing either header.
		body = body.concat(fieldAt(base, WasmGcTypePlan.arrayElementTypeFieldIndex(), 0))
			.concat([LocalSet(sourceType), I32Const(-1), LocalSet(readKind), LocalGet(sourceType),
				I32Const(plan.runtimeTypeIds.id(Dyn)), I32Eq, If(null), I32Const(0), LocalSet(readKind), End]);
		for (offset in 0...enumStorage.length) {
			var entry = enumStorage[offset];
			body = body.concat([LocalGet(sourceType), I32Const(entry.id), I32Eq, LocalGet(sourceType), LocalGet(1), I32Eq,
				I32And, If(null), I32Const(offset + 1), LocalSet(readKind), End]);
		}
		body = body.concat([LocalGet(readKind), I32Const(0), I32LtS, If(null)]).concat(failure(throws)).concat([End])
			.concat(sourceElement(false));
		for (i in [6, 7, 8]) body = body.concat([LocalGet(i), RefIsNull, If(null)]).concat(failure(throws)).concat([End]);
		body = body.concat(fieldAt(base, WasmGcTypePlan.arrayLengthFieldIndex(), 0)).concat([LocalSet(length), Block(null), Loop(null),
			LocalGet(index), LocalGet(length), I32Eq, BrIf(1)]).concat(sourceElement(true)).concat([LocalGet(item),
			LocalGet(8), RefCast({nullable:false, heap:Type(plan.closureTypeIndex)}), StructGet(plan.closureTypeIndex, 0), I32Const(1), I32ShrU,
			CallIndirect(acceptSignature), I32Eqz, If(null)]).concat(failure(throws)).concat([End, LocalGet(index), I32Const(1), I32Add, LocalSet(index), Br(0), End, End,
			LocalGet(length), LocalGet(1), LocalGet(2), LocalGet(3), LocalGet(4), LocalGet(5), Call(allocator), LocalSet(candidate)]);
		for (pair in [{field:WasmGcTypePlan.VALUE_ARRAY_READ_BRIDGE_FIELD, arg:6}, {field:WasmGcTypePlan.VALUE_ARRAY_WRITE_BRIDGE_FIELD, arg:7},
				{field:WasmGcTypePlan.VALUE_ARRAY_ACCEPTS_BRIDGE_FIELD, arg:8}])
			body = body.concat([LocalGet(candidate), RefCast({nullable:false, heap:Type(w)}), LocalGet(pair.arg), StructSet(w, pair.field)]);
		body = body.concat([I32Const(0), LocalSet(index), Block(null), Loop(null), LocalGet(index), LocalGet(length), I32Eq, BrIf(1)])
			.concat(sourceElement(true)).concat([LocalGet(candidate), LocalGet(index), LocalGet(item), LocalGet(7), RefCast({nullable:false, heap:Type(plan.closureTypeIndex)}),
			StructGet(plan.closureTypeIndex, 0), I32Const(1), I32ShrU, CallIndirect(writeSignature),
			LocalGet(index), I32Const(1), I32Add, LocalSet(index), Br(0), End, End,
			I32Const(1), ArrayNewDefault(marker), LocalSet(forward), LocalGet(forward), RefCast({nullable:false, heap:Type(marker)}), I32Const(0), LocalGet(candidate),
			RefCast({nullable:false, heap:Type(w)}), ArraySet(marker), LocalGet(candidate), RefCast({nullable:false, heap:Type(w)}),
			LocalGet(0), StructSet(w, WasmGcTypePlan.VALUE_ARRAY_FORWARD_HEADER_FIELD), LocalGet(0), LocalGet(forward), RefCast({nullable:false, heap:Type(marker)}),
			StructSet(base, WasmGcTypePlan.arrayDataFieldIndex()), LocalGet(0), LocalGet(1), StructSet(base, WasmGcTypePlan.arrayElementTypeFieldIndex()),
			LocalGet(0), Return]);
		return new WasmFunction(native.name, plan.wasmFunctionType(native.arguments, native.result), [
			{type:I32}, {type:I32}, {type:plan.valueType(Array(Dyn))}, {type:Ref({nullable:true, heap:Type(marker)})},
			{type:plan.valueType(Dyn)}, {type:plan.valueType(Array(Dyn))}, {type:I32}, {type:I32}], body);
	}

	/** Stage conversion and any missing reference lane before modifying the live collection. */
	static function dynamicWrite(plan:WasmGcTypePlan, throws:Bool, newLike:Int, move:Int, ensure:Int, insert:Int, writeSignature:Int):WasmFunction {
		var w = plan.valueArrayWrapperTypeIndex, refs = plan.valueArrayReferenceLaneTypeIndex, staged = 3, closure = 4, position = 5;
		var body:Array<WasmInstruction> = [LocalGet(0), I32Const(1), Call(newLike), LocalSet(staged)];
		body = body.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_WRITE_BRIDGE_FIELD)).concat([LocalSet(closure), LocalGet(closure), RefIsNull, If(null)])
			.concat(failure(throws)).concat([End, LocalGet(staged), I32Const(0), LocalGet(2), LocalGet(closure),
				RefCast({nullable:false, heap:Type(plan.closureTypeIndex)}), StructGet(plan.closureTypeIndex, 0), I32Const(1), I32ShrU, CallIndirect(writeSignature)]);
		// If the staged element has a mixed reference lane, allocate the live lane before extending or shifting.
		body = body.concat(fieldAt(w, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_FIELD, staged)).concat([RefIsNull, I32Eqz])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_FIELD)).concat([RefIsNull, I32And, If(null),
				LocalGet(0), RefCast({nullable:false, heap:Type(w)})])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_CAPACITY_FIELD)).concat(field(w, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_STRIDE_FIELD))
			.concat([I32Mul, ArrayNewDefault(refs), StructSet(w, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_FIELD), End,
				LocalGet(0), LocalGet(1)]);
		if (insert >= 0) body = body.concat([Call(insert), LocalSet(position)]);
		else body = body.concat([Call(ensure), LocalGet(1), LocalSet(position)]);
		body = body.concat([LocalGet(0), LocalGet(position), LocalGet(staged), I32Const(0), I32Const(1), Call(move), Return]);
		var name = insert >= 0 ? "$value-array:runtime:insert-value" : "$value-array:runtime:store-value";
		return new WasmFunction(name, plan.wasmFunctionType([Array(Dyn),I32,Dyn], Void),
			[{type:plan.valueType(Array(Dyn))}, {type:Ref({nullable:true, heap:Type(plan.closureTypeIndex)})}, {type:I32}], body);
	}

	/** Allocate the same lane layout and retain the shared dynamic bridge closures. */
	public static function newLike(plan:WasmGcTypePlan, allocator:Int, name:String):WasmFunction {
		var w = plan.valueArrayWrapperTypeIndex, result = 2;
		var body:Array<WasmInstruction> = [LocalGet(1)];
		for (index in [WasmGcTypePlan.arrayElementTypeFieldIndex(), WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD,
				WasmGcTypePlan.VALUE_ARRAY_REFERENCE_STRIDE_FIELD, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD, WasmGcTypePlan.VALUE_ARRAY_VALIDITY_FIELD])
			body = body.concat(field(w, index));
		body = body.concat([Call(allocator), LocalSet(result)]);
		for (index in [WasmGcTypePlan.VALUE_ARRAY_READ_BRIDGE_FIELD, WasmGcTypePlan.VALUE_ARRAY_WRITE_BRIDGE_FIELD, WasmGcTypePlan.VALUE_ARRAY_ACCEPTS_BRIDGE_FIELD])
			body = body.concat([LocalGet(result), RefCast({nullable:false, heap:Type(w)})]).concat(field(w, index)).concat([StructSet(w, index)]);
		body = body.concat([LocalGet(result), Return]);
		return new WasmFunction(name, plan.wasmFunctionType([Array(Dyn),I32], Array(Dyn)), [{type:plan.valueType(Array(Dyn))}], body);
	}

	/** Grow both lanes before publishing either one so allocation failure leaves aliases unchanged. */
	public static function replaceCapacity(plan:WasmGcTypePlan, native:IrNative, throws:Bool):WasmFunction {
		if (native.arguments.length != 2) throw "Invalid Wasm GC value-array ensure";
		var w = plan.valueArrayWrapperTypeIndex, l32 = plan.valueArrayI32LaneTypeIndex, l64 = plan.valueArrayI64LaneTypeIndex,
			refs = plan.valueArrayReferenceLaneTypeIndex, oldCap = 2, newCap = 3, oldPayload = 4, newPayload = 5,
			bitmap = 6, refCount = 7, total = 8, oldData = 9, newData = 10, oldRef = 11, newRef = 12;
		var arrayType:WasmValueType = Ref({nullable:true, heap:Array});
		var locals:Array<WasmLocal> = [{type:I32}, {type:I32}, {type:I32}, {type:I32}, {type:I32}, {type:I32}, {type:I64},
			{type:arrayType}, {type:arrayType}, {type:arrayType}, {type:arrayType}];
		var body:Array<WasmInstruction> = field(w, WasmGcTypePlan.VALUE_ARRAY_CAPACITY_FIELD)
			.concat([LocalSet(oldCap),LocalGet(1),LocalSet(newCap)]);
		// Compute rounded payload words and validate both new lane sizes before allocating.
		for (pair in [{cap:oldCap, out:oldPayload}, {cap:newCap, out:newPayload}]) {
			body = body.concat([LocalGet(pair.cap), I64ExtendI32U]).concat(field(w, WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD))
				.concat([I64ExtendI32U, I64Mul]).concat(field(w, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD))
				.concat([I64ExtendI32U, I64Const(1), I64Sub, I64Add]).concat(field(w, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD))
				.concat([I64ExtendI32U, I64DivS, LocalTee(total), I64Const(0x7fffffff), I64LeS, I32Eqz, If(null)])
				.concat(failure(throws)).concat([End, LocalGet(total), I32WrapI64, LocalSet(pair.out)]);
		}
		body = body.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_VALIDITY_FIELD)).concat([If(null), LocalGet(newCap), I64ExtendI32U])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD)).concat([I64ExtendI32U, I64Const(1), I64Sub, I64Add])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD)).concat([I64ExtendI32U, I64DivS, LocalGet(newPayload), I64ExtendI32U,
				I64Add, LocalSet(total), Else, LocalGet(newPayload), I64ExtendI32U, LocalSet(total), End,
				LocalGet(total), I64Const(0x7fffffff), I64LeS, I32Eqz, If(null)]).concat(failure(throws)).concat([End,
				LocalGet(newCap), I64ExtendI32U]).concat(field(w, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_STRIDE_FIELD))
			.concat([I64ExtendI32U, I64Mul, LocalTee(total), I64Const(0x7fffffff), I64LeS, I32Eqz, If(null)])
			.concat(failure(throws)).concat([End, LocalGet(total), I32WrapI64, LocalSet(refCount)]);
		body = body.concat(field(w, WasmGcTypePlan.arrayDataFieldIndex())).concat([LocalSet(oldData)])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_FIELD)).concat([LocalSet(oldRef)]);
		// Reference-only arrays use the inherited data lane. Mixed arrays keep the reference lane lazy.
		body = body.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD)).concat([I32Eqz])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_VALIDITY_FIELD)).concat([I32Eqz, I32And])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_STRIDE_FIELD)).concat([I32Eqz, I32Eqz, I32And, If(null),
				LocalGet(refCount), ArrayNewDefault(refs), LocalSet(newData), LocalGet(newData), RefCast({nullable:false, heap:Type(refs)}), I32Const(0),
				LocalGet(oldData), RefCast({nullable:false, heap:Type(refs)}), I32Const(0), LocalGet(oldCap)])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_STRIDE_FIELD)).concat([I32Mul, ArrayCopy(refs, refs), Else]);
		// Scalar arrays: allocate payload plus bitmap and relocate the bitmap to its new offset.
		body = body.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_VALIDITY_FIELD)).concat([If(I32), LocalGet(newCap), I64ExtendI32U])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD)).concat([I64ExtendI32U, I64Const(1), I64Sub, I64Add])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD)).concat([I64ExtendI32U, I64DivS, I32WrapI64, Else, I32Const(0), End,
				LocalSet(bitmap), LocalGet(newPayload), LocalGet(bitmap), I32Add, LocalSet(bitmap)])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD)).concat([I32Const(32), I32Eq, If(null)]);
		for (lane in [l32, l64]) {
			body = body.concat([LocalGet(bitmap), ArrayNewDefault(lane), LocalSet(newData), LocalGet(newData), RefCast({nullable:false, heap:Type(lane)}),
				I32Const(0), LocalGet(oldData), RefCast({nullable:false, heap:Type(lane)}), I32Const(0), LocalGet(oldPayload), ArrayCopy(lane, lane)])
				.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_VALIDITY_FIELD)).concat([If(null), LocalGet(newData), RefCast({nullable:false, heap:Type(lane)}),
					LocalGet(newPayload), LocalGet(oldData), RefCast({nullable:false, heap:Type(lane)}), LocalGet(oldPayload), LocalGet(oldCap), I64ExtendI32U])
				.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD)).concat([I64ExtendI32U, I64Const(1), I64Sub, I64Add])
				.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD)).concat([I64ExtendI32U, I64DivS, I32WrapI64, ArrayCopy(lane, lane), End]);
			if (lane == l32) body.push(Else);
		}
		body = body.concat([End, LocalGet(oldRef), RefIsNull, I32Eqz, If(null), LocalGet(refCount), ArrayNewDefault(refs), LocalSet(newRef),
			LocalGet(newRef), RefCast({nullable:false, heap:Type(refs)}), I32Const(0), LocalGet(oldRef), RefCast({nullable:false, heap:Type(refs)}),
			I32Const(0), LocalGet(oldCap)]).concat(field(w, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_STRIDE_FIELD))
			.concat([I32Mul, ArrayCopy(refs, refs), End, End]);
		body = body.concat([LocalGet(0), RefCast({nullable:false, heap:Type(w)}), LocalGet(newData), RefCast({nullable:false, heap:Array}),
			StructSet(w, WasmGcTypePlan.arrayDataFieldIndex()), LocalGet(0), RefCast({nullable:false, heap:Type(w)}), LocalGet(newRef),
			StructSet(w, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_FIELD), LocalGet(0), RefCast({nullable:false, heap:Type(w)}), LocalGet(newCap),
			StructSet(w, WasmGcTypePlan.VALUE_ARRAY_CAPACITY_FIELD),Return]);
		return new WasmFunction(native.name, plan.wasmFunctionType(native.arguments, native.result), locals, body);
	}

	/** Index of the element's bitmap word, following the capacity-sized payload. */
	public static function bitmapWordIndex(wrapper:Int):Array<WasmInstruction> {
		var bits = field(wrapper, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD);
		return field(wrapper, WasmGcTypePlan.VALUE_ARRAY_CAPACITY_FIELD).concat([I64ExtendI32U])
			.concat(field(wrapper, WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD)).concat([I64ExtendI32U, I64Mul])
			.concat(bits).concat([I64ExtendI32U, I64Const(1), I64Sub, I64Add])
			.concat(bits).concat([I64ExtendI32U, I64DivS, LocalGet(1), I64ExtendI32U])
			.concat(bits).concat([I64ExtendI32U, I64DivS, I64Add, I32WrapI64]);
	}

	public static function bitmapBit(wrapper:Int):Array<WasmInstruction>
		return [LocalGet(1)].concat(field(wrapper, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD)).concat([I32RemS, I64ExtendI32U]);

	/** Leaves a boolean on the stack; arrays without a validity bitmap are always initialized. */
	public static function initialized(plan:WasmGcTypePlan):Array<WasmInstruction> {
		var wrapper = plan.valueArrayWrapperTypeIndex, lane32 = plan.valueArrayI32LaneTypeIndex, lane64 = plan.valueArrayI64LaneTypeIndex;
		var body = field(wrapper, WasmGcTypePlan.VALUE_ARRAY_VALIDITY_FIELD).concat([If(I32)])
			.concat(field(wrapper, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD)).concat([I32Const(32), I32Eq, If(I64)])
			.concat(field(wrapper, WasmGcTypePlan.arrayDataFieldIndex())).concat([RefCast({nullable:false, heap:Type(lane32)})])
			.concat(bitmapWordIndex(wrapper)).concat([ArrayGet(lane32), I64ExtendI32U, Else])
			.concat(field(wrapper, WasmGcTypePlan.arrayDataFieldIndex())).concat([RefCast({nullable:false, heap:Type(lane64)})])
			.concat(bitmapWordIndex(wrapper)).concat([ArrayGet(lane64), End]);
		return body.concat(bitmapBit(wrapper)).concat([I64ShrU, I64Const(1), I64And, I64Eqz, I32Eqz, Else, I32Const(1), End]);
	}

	static function validityOperation(plan:WasmGcTypePlan, native:IrNative, throws:Bool):WasmFunction {
		if (native.arguments.length != 2) throw 'Invalid Wasm GC value-array validity operation ${native.symbol}';
		var wrapper = plan.valueArrayWrapperTypeIndex, lane32 = plan.valueArrayI32LaneTypeIndex, lane64 = plan.valueArrayI64LaneTypeIndex;
		var body:Array<WasmInstruction> = [LocalGet(0), RefIsNull, If(null)];
		body = body.concat(failure(throws)).concat([End, LocalGet(1), I32Const(0), I32LtS]);
		body = body.concat(field(wrapper, WasmGcTypePlan.arrayLengthFieldIndex())).concat([LocalGet(1), I32LeS, I32Or, If(null)]);
		body = body.concat(failure(throws)).concat([End]);
		if (native.symbol == "__value_array_mark") {
			body = body.concat(field(wrapper, WasmGcTypePlan.VALUE_ARRAY_VALIDITY_FIELD)).concat([If(null)])
				.concat(field(wrapper, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD)).concat([I32Const(32), I32Eq, If(null)]);
			for (lane in [lane32, lane64]) {
				body = body.concat(field(wrapper, WasmGcTypePlan.arrayDataFieldIndex())).concat([RefCast({nullable:false, heap:Type(lane)})])
					.concat(bitmapWordIndex(wrapper))
					.concat(field(wrapper, WasmGcTypePlan.arrayDataFieldIndex())).concat([RefCast({nullable:false, heap:Type(lane)})])
					.concat(bitmapWordIndex(wrapper)).concat([ArrayGet(lane)]);
				if (lane == lane32) body.push(I64ExtendI32U);
				body = body.concat([I64Const(1)]).concat(bitmapBit(wrapper)).concat([I64Shl, I64Or]);
				if (lane == lane32) body.push(I32WrapI64);
				body.push(ArraySet(lane));
				if (lane == lane32) body.push(Else);
			}
			body = body.concat([End, End]);
		} else {
			body = body.concat(initialized(plan));
			if (native.symbol == "__value_array_validate") body = body.concat([I32Eqz, If(null)]).concat(failure(throws)).concat([End]);
		}
		body.push(Return);
		return new WasmFunction(native.name, plan.wasmFunctionType(native.arguments, native.result), [], body);
	}

	public static function allocate(plan:WasmGcTypePlan, native:IrNative, throws:Bool):WasmFunction {
		if (native.arguments.length != 6) throw "Invalid Wasm GC value-array allocator";
		var error = failure(throws), data = 9, references = 10,
			arrayReference:WasmValueType = Ref({nullable: true, heap: Array}),
			locals:Array<WasmLocal> = [{type: I32}, {type: I64}, {type: I64}, {type: arrayReference}, {type: arrayReference}],
			body:Array<WasmInstruction> = [];
		// Reject invalid metadata before allocating any object. Length and strides are non-negative and scalar strides are byte aligned.
		body = body.concat([LocalGet(0), I32Const(0), I32LtS, LocalGet(2), I32Const(0), I32LtS, I32Or,
			LocalGet(3), I32Const(0), I32LtS, I32Or, LocalGet(2), I32Const(7), I32And, I32Or,
			LocalGet(4), I32Const(32), I32Eq, LocalGet(4), I32Const(64), I32Eq, I32Or, I32Eqz, I32Or, If(null)]);
		body = body.concat(error).concat([End]);
		// Capacity starts at four and otherwise equals the requested length.
		body = body.concat([LocalGet(0), I32Const(4), I32LtS, If(I32), I32Const(4), Else, LocalGet(0), End, LocalSet(6)]);
		// Scalar words = ceil(capacity * strideBits / wordBits) plus the optional validity bitmap.
		body = body.concat([LocalGet(6), I64ExtendI32U, LocalGet(2), I64ExtendI32U, I64Mul,
			LocalGet(4), I64ExtendI32U, I64Const(1), I64Sub, I64Add, LocalGet(4), I64ExtendI32U, I64DivS, LocalSet(7),
			LocalGet(5), If(null), LocalGet(7), LocalGet(6), I64ExtendI32U, LocalGet(4), I64ExtendI32U, I64Const(1), I64Sub,
			I64Add, LocalGet(4), I64ExtendI32U, I64DivS, I64Add, LocalSet(7), End,
			LocalGet(6), I64ExtendI32U, LocalGet(3), I64ExtendI32U, I64Mul, LocalSet(8),
			LocalGet(7), I64Const(0x7fffffff), I64LeS, I32Eqz, LocalGet(8), I64Const(0x7fffffff), I64LeS, I32Eqz, I32Or, If(null)]);
		body = body.concat(error).concat([End]);
		// The common data field is always non-null: it holds the scalar lane, or the reference lane when that is the only lane.
		body = body.concat([LocalGet(7), I64Eqz, If(null),
			LocalGet(8), I64Eqz, If(null), LocalGet(4), I32Const(32), I32Eq, If(null),
			I32Const(0), ArrayNewDefault(plan.valueArrayI32LaneTypeIndex), LocalSet(data), Else,
			I32Const(0), ArrayNewDefault(plan.valueArrayI64LaneTypeIndex), LocalSet(data), End,
			Else, LocalGet(8), I32WrapI64, ArrayNewDefault(plan.valueArrayReferenceLaneTypeIndex), LocalSet(data), End,
			Else, LocalGet(4), I32Const(32), I32Eq, If(null),
			LocalGet(7), I32WrapI64, ArrayNewDefault(plan.valueArrayI32LaneTypeIndex), LocalSet(data),
			Else, LocalGet(7), I32WrapI64, ArrayNewDefault(plan.valueArrayI64LaneTypeIndex), LocalSet(data), End, End]);
		body = body.concat([LocalGet(0), LocalGet(data), RefCast({nullable: false, heap: Array}), LocalGet(1), LocalGet(references),
			LocalGet(2), LocalGet(3), LocalGet(4), LocalGet(5),
			RefNull(Type(plan.closureTypeIndex)), RefNull(Type(plan.closureTypeIndex)), RefNull(Type(plan.closureTypeIndex)), LocalGet(6),
			RefNull(Type(plan.arrayType(plan.arrayElementTypes()[0]))),
			StructNew(plan.valueArrayWrapperTypeIndex), Return]);
		return new WasmFunction(native.name, plan.wasmFunctionType(native.arguments, native.result), locals, body);
	}

	static function setBridge(plan:WasmGcTypePlan, native:IrNative, throws:Bool):WasmFunction {
		if (native.arguments.length != 4) throw "Invalid Wasm GC value-array bridge";
		var body:Array<WasmInstruction> = [LocalGet(1), RefIsNull, LocalGet(2), RefIsNull, I32Or, LocalGet(3), RefIsNull, I32Or, If(null)];
		body = body.concat(failure(throws)).concat([End]);
		for (field in 0...3) body = body.concat([LocalGet(0), RefCast({nullable: false, heap: Type(plan.valueArrayWrapperTypeIndex)}),
			LocalGet(field + 1), StructSet(plan.valueArrayWrapperTypeIndex, WasmGcTypePlan.VALUE_ARRAY_READ_BRIDGE_FIELD + field)]);
		body.push(Return);
		return new WasmFunction(native.name, plan.wasmFunctionType(native.arguments, native.result), [], body);
	}


	static function referenceSlot(plan:WasmGcTypePlan, native:IrNative, throws:Bool, write:Bool, clear:Bool):WasmFunction {
		if (native.arguments.length != (write && !clear ? 4 : 3)) throw "Invalid Wasm GC value-array reference access";
		var wrapper = plan.valueArrayWrapperTypeIndex, lane = plan.valueArrayReferenceLaneTypeIndex,
			laneLocal = native.arguments.length, laneType:WasmValueType = Ref({nullable: true, heap: Type(lane)}),
			body:Array<WasmInstruction> = [LocalGet(0), RefIsNull, If(null)];
		body = body.concat(failure(throws)).concat([End]);
		// Check the logical element and field bounds before indexing either backing array.
		body = body.concat([LocalGet(1), I32Const(0), I32LtS, LocalGet(0), RefCast({nullable: false, heap: Type(wrapper)}),
			StructGet(wrapper, WasmGcTypePlan.arrayLengthFieldIndex()), LocalGet(1), I32LeS, I32Or,
			LocalGet(2), I32Const(0), I32LtS, I32Or, LocalGet(0), RefCast({nullable: false, heap: Type(wrapper)}),
			StructGet(wrapper, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_STRIDE_FIELD), LocalGet(2), I32LeS, I32Or, If(null)]);
		body = body.concat(failure(throws)).concat([End]);
		if (!write) body = body.concat(initialized(plan)).concat([I32Eqz, If(null)]).concat(failure(throws)).concat([End]);
		// With no scalar payload or validity bitmap, the inherited data field holds the sole reference lane.
		body = body.concat([LocalGet(0), RefCast({nullable: false, heap: Type(wrapper)}),
			StructGet(wrapper, WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD), I32Eqz,
			LocalGet(0), RefCast({nullable: false, heap: Type(wrapper)}), StructGet(wrapper, WasmGcTypePlan.VALUE_ARRAY_VALIDITY_FIELD), I32Eqz,
			I32And, If(null), LocalGet(0), RefCast({nullable: false, heap: Type(wrapper)}), StructGet(wrapper, WasmGcTypePlan.arrayDataFieldIndex()),
			RefCast({nullable: false, heap: Type(lane)}), LocalSet(laneLocal), Else,
			LocalGet(0), RefCast({nullable: false, heap: Type(wrapper)}), StructGet(wrapper, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_FIELD),
			RefCast({nullable: true, heap: Type(lane)}), LocalSet(laneLocal), End]);
		// A mixed array starts without a reference lane. Null reads and clears need no allocation; the first
		// non-null reference allocates one backing array for the whole collection.
		body = body.concat([LocalGet(laneLocal), RefIsNull, If(null)]);
		if (!write) body = body.concat([RefNull(Any), Return]);
		else if (clear) body.push(Return);
		else {
			body = body.concat([LocalGet(3), RefIsNull, If(null), Return, End,
				LocalGet(0), RefCast({nullable: false, heap: Type(wrapper)}), StructGet(wrapper, WasmGcTypePlan.VALUE_ARRAY_CAPACITY_FIELD),
				LocalGet(0), RefCast({nullable: false, heap: Type(wrapper)}), StructGet(wrapper, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_STRIDE_FIELD),
				I32Mul, ArrayNewDefault(lane), LocalSet(laneLocal),
				LocalGet(0), RefCast({nullable: false, heap: Type(wrapper)}), LocalGet(laneLocal),
				StructSet(wrapper, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_FIELD)]);
		}
		body = body.concat([End, LocalGet(laneLocal), RefCast({nullable: false, heap: Type(lane)}), LocalGet(1),
			LocalGet(0), RefCast({nullable: false, heap: Type(wrapper)}), StructGet(wrapper, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_STRIDE_FIELD), I32Mul, LocalGet(2), I32Add]);
		if (write) {
			body.push(clear ? RefNull(Any) : LocalGet(3));
			body.push(ArraySet(lane));
		} else body.push(ArrayGet(lane));
		body.push(Return);
		return new WasmFunction(native.name, plan.wasmFunctionType(native.arguments, native.result), [{type: laneType}], body);
	}
}
