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

	public static function register(module:WasmModule, functions:Map<String, Int>, plan:WasmGcTypePlan, program:IrProgram, used:Map<String, Bool>):Void {
		var throws = WasmModuleSupport.hasExceptions(program);
		var resizeUsed = false, insertUsed = false, reverseUsed = false, rangeUsed = false, spliceUsed = false, dynamicInsert = false, dynamicStore = false;
		var dynamicOperations:Map<String, Bool> = [];
		for (native in program.natives) if (used.exists(native.name)) {
			if (native.symbol == "__value_array_resize") resizeUsed = true;
			if (native.symbol == "__value_array_insert_empty") insertUsed = true;
			if (native.symbol == "__value_array_reverse") reverseUsed = true;
			if (native.symbol == "__value_array_copy" || native.symbol == "__value_array_slice" || native.symbol == "__value_array_concat") rangeUsed = true;
			if (native.symbol == "__value_array_splice") { rangeUsed = true; spliceUsed = true; }
			if (native.symbol == "__value_array_remove_at") { rangeUsed = true; spliceUsed = true; }
			if (plan.valueArrayWrapperTypeIndex >= 0 && (native.name == "__array_insert_any" || native.name == "__array_unshift_any")) { insertUsed = true; dynamicInsert = true; }
			if (plan.valueArrayWrapperTypeIndex >= 0 && (native.name == "__array_set_any" || native.name == "__array_push_any")) dynamicStore = true;
			if (plan.valueArrayWrapperTypeIndex >= 0) switch native.name {
				case "__array_resize_any": resizeUsed = true; dynamicOperations.set("resize", true);
				case "__array_reverse_any": reverseUsed = true; dynamicOperations.set("reverse", true);
				case "__array_copy_any": rangeUsed = true; dynamicOperations.set("copy", true);
				case "__array_slice_any": rangeUsed = true; dynamicOperations.set("slice", true);
				case "__array_splice_any": rangeUsed = true; spliceUsed = true; dynamicOperations.set("splice", true);
				case "__array_pop_any": resizeUsed = true; dynamicOperations.set("resize", true);
				case "__array_remove_at_any": rangeUsed = true; spliceUsed = true; dynamicOperations.set("remove_at", true);
				case "__array_shift_any": rangeUsed = true; spliceUsed = true; dynamicOperations.set("splice", true);
				case "__array_concat_any": rangeUsed = true; dynamicOperations.set("concat", true);
				default:
			}
		}
		if (dynamicStore || dynamicInsert) rangeUsed = true;
		var ensureIndex = -1, clearIndex = -1, moveIndex = -1, swapIndex = -1, newLikeIndex = -1, resizeIndex = -1;
		if (resizeUsed || insertUsed || reverseUsed || rangeUsed) {
			var ensureNative:IrNative = {name:"$value-array:internal:ensure", library:"haxeon_runtime", symbol:"__value_array_ensure", arguments:[Array(Dyn), I32], result:Void};
			var clearNative:IrNative = {name:"$value-array:internal:clear", library:"haxeon_runtime", symbol:"__value_array_clear", arguments:[Array(Dyn), I32], result:Void};
			ensureIndex = module.addFunction(ensure(plan, ensureNative, throws));
			clearIndex = module.addFunction(clearElement(plan, clearNative, throws));
		}
		if (insertUsed || reverseUsed || rangeUsed) {
			var read:IrNative = {name:"$value-array:internal:read-byte", library:"haxeon_runtime", symbol:"__value_array_read_i32", arguments:[Array(Dyn),I32,I32,I32,Bool], result:I32};
			var write:IrNative = {name:"$value-array:internal:write-byte", library:"haxeon_runtime", symbol:"__value_array_write_i32", arguments:[Array(Dyn),I32,I32,I32,I32], result:Void};
			var readRef:IrNative = {name:"$value-array:internal:read-ref", library:"haxeon_runtime", symbol:"__value_array_read_ref", arguments:[Array(Dyn),I32,I32], result:IrValueLaneReference.type()};
			var writeRef:IrNative = {name:"$value-array:internal:write-ref", library:"haxeon_runtime", symbol:"__value_array_write_ref", arguments:[Array(Dyn),I32,I32,IrValueLaneReference.type()], result:Void};
			var valid:IrNative = {name:"$value-array:internal:valid", library:"haxeon_runtime", symbol:"__value_array_is_initialized", arguments:[Array(Dyn),I32], result:Bool};
			var mark:IrNative = {name:"$value-array:internal:mark", library:"haxeon_runtime", symbol:"__value_array_mark", arguments:[Array(Dyn),I32], result:Void};
			var readIndex = module.addFunction(scalarSlot(plan, read, throws)), writeIndex = module.addFunction(scalarSlot(plan, write, throws)),
				readRefIndex = module.addFunction(referenceSlot(plan, readRef, throws, false, false)), writeRefIndex = module.addFunction(referenceSlot(plan, writeRef, throws, true, false)),
				validIndex = module.addFunction(validityOperation(plan, valid, throws)), markIndex = module.addFunction(validityOperation(plan, mark, throws));
			if (insertUsed || rangeUsed) moveIndex = module.addFunction(moveElement(plan, readIndex, writeIndex, readRefIndex, writeRefIndex, validIndex, markIndex, clearIndex));
			if (reverseUsed) swapIndex = module.addFunction(swapElements(plan, readIndex, writeIndex, readRefIndex, writeRefIndex, validIndex, markIndex, clearIndex));
		}
		if (rangeUsed) {
			var allocator:IrNative = {name:"$value-array:internal:allocate", library:"haxeon_runtime", symbol:"__value_array_alloc", arguments:[I32,TypeRef,I32,I32,I32,Bool], result:Array(Dyn)};
			newLikeIndex = module.addFunction(newLike(plan, module.addFunction(allocate(plan, allocator, throws))));
		}
		if (spliceUsed) {
			var resizeNative:IrNative = {name:"$value-array:internal:resize", library:"haxeon_runtime", symbol:"__value_array_resize", arguments:[Array(Dyn),I32], result:Void};
			resizeIndex = module.addFunction(resize(plan, resizeNative, throws, ensureIndex, clearIndex));
		}
		var dynamicInsertIndex = -1;
		if (dynamicInsert && plan.valueArrayWrapperTypeIndex >= 0) {
			var insertNative:IrNative = {name:"$value-array:runtime:insert", library:"haxeon_runtime", symbol:"__value_array_insert_empty", arguments:[Array(Dyn),I32], result:I32};
			dynamicInsertIndex = module.addFunction(insertEmpty(plan, insertNative, throws, ensureIndex, clearIndex, moveIndex));
			functions.set(insertNative.name, dynamicInsertIndex);
		}
		if (dynamicStore || dynamicInsert) {
			var writeSignature = module.typeIndex(plan.wasmFunctionType([Array(Dyn),I32,Dyn], Void));
			if (dynamicStore) functions.set("$value-array:runtime:store-value", module.addFunction(dynamicWrite(plan, throws, newLikeIndex, moveIndex, ensureIndex, -1, writeSignature)));
			if (dynamicInsert) functions.set("$value-array:runtime:insert-value", module.addFunction(dynamicWrite(plan, throws, newLikeIndex, moveIndex, ensureIndex, dynamicInsertIndex, writeSignature)));
		}
		var retypeAllocator = -1;
		for (native in program.natives) if (used.exists(native.name) && native.symbol == "__value_array_retype") {
			var allocator:IrNative = {name:"$value-array:internal:retype-allocate", library:"haxeon_runtime", symbol:"__value_array_alloc", arguments:[I32,TypeRef,I32,I32,I32,Bool], result:Array(Dyn)};
			retypeAllocator = module.addFunction(allocate(plan, allocator, throws));
			break;
		}
		for (operation in ["resize", "reverse", "copy", "slice", "splice", "concat", "remove_at"]) if (dynamicOperations.exists(operation)) {
			var arguments:Array<IrType> = switch operation {
				case "resize", "remove_at": [Array(Dyn), I32];
				case "slice", "splice": [Array(Dyn), I32, I32];
				case "concat": [Array(Dyn), Array(Dyn)];
				default: [Array(Dyn)];
			};
			var result:IrType = operation == "resize" || operation == "reverse" || operation == "remove_at" ? Void : Array(Dyn);
			var internal:IrNative = {name:"$value-array:runtime:" + operation, library:"haxeon_runtime", symbol:"__value_array_" + operation, arguments:arguments, result:result};
			var fn = switch operation {
				case "resize": resize(plan, internal, throws, ensureIndex, clearIndex);
				case "reverse": reverse(plan, internal, throws, swapIndex);
				case "copy", "slice": rangeCopy(plan, internal, throws, newLikeIndex, moveIndex);
				case "splice": splice(plan, internal, throws, newLikeIndex, moveIndex, resizeIndex);
				case "remove_at": removeAt(plan, internal, throws, moveIndex, resizeIndex);
				case "concat": concat(plan, internal, throws, newLikeIndex, moveIndex);
				default: throw "Invalid dynamic inline array operation";
			};
			functions.set(internal.name, module.addFunction(fn));
		}
		for (native in program.natives) if (used.exists(native.name) && supports(native.symbol)) {
			if (plan.valueArrayWrapperTypeIndex < 0) throw "Missing Wasm GC value-array type plan";
			var fn = switch native.symbol {
				case "__value_array_alloc": allocate(plan, native, throws);
				case "__value_array_set_bridge": setBridge(plan, native, throws);
				case "__value_array_retype": retype(module, plan, native, throws, retypeAllocator);
				case "__value_array_read_ref": referenceSlot(plan, native, throws, false, false);
				case "__value_array_write_ref": referenceSlot(plan, native, throws, true, false);
				case "__value_array_clear_ref": referenceSlot(plan, native, throws, true, true);
				case "__value_array_clear": clearElement(plan, native, throws);
				case "__value_array_ensure": ensure(plan, native, throws);
				case "__value_array_resize": resize(plan, native, throws, ensureIndex, clearIndex);
				case "__value_array_insert_empty": insertEmpty(plan, native, throws, ensureIndex, clearIndex, moveIndex);
				case "__value_array_reverse": reverse(plan, native, throws, swapIndex);
				case "__value_array_copy", "__value_array_slice": rangeCopy(plan, native, throws, newLikeIndex, moveIndex);
				case "__value_array_concat": concat(plan, native, throws, newLikeIndex, moveIndex);
				case "__value_array_splice": splice(plan, native, throws, newLikeIndex, moveIndex, resizeIndex);
				case "__value_array_remove_at": removeAt(plan, native, throws, moveIndex, resizeIndex);
				case "__value_array_is_initialized", "__value_array_validate", "__value_array_mark": validityOperation(plan, native, throws);
				case "__value_array_read_i32", "__value_array_read_i64", "__value_array_read_bool", "__value_array_read_f32", "__value_array_read_f64",
					"__value_array_write_i32", "__value_array_write_i64", "__value_array_write_bool", "__value_array_write_f32", "__value_array_write_f64",
					"__value_array_read_ptr", "__value_array_write_ptr", "__value_array_read_type", "__value_array_write_type",
					"__value_array_read_callback", "__value_array_write_callback",
					"__value_array_clear_scalar": scalarSlot(plan, native, throws);
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

	static function failure(throws:Bool):Array<WasmInstruction> return throws ? [RefNull(Any), Throw(0)] : [Unreachable];

	static function field(wrapper:Int, index:Int):Array<WasmInstruction>
		return [LocalGet(0), RefCast({nullable:false, heap:Type(wrapper)}), StructGet(wrapper, index)];
	static function fieldAt(wrapper:Int, index:Int, array:Int):Array<WasmInstruction>
		return [LocalGet(array), RefCast({nullable:false, heap:Type(wrapper)}), StructGet(wrapper, index)];

	static function removeAt(plan:WasmGcTypePlan, native:IrNative, throws:Bool, move:Int, resize:Int):WasmFunction {
		if (native.arguments.length != 2 || move < 0 || resize < 0) throw "Invalid Wasm GC value-array removal";
		var w = plan.valueArrayWrapperTypeIndex, size = 2, cursor = 3, body:Array<WasmInstruction> = [LocalGet(0), RefIsNull, If(null)];
		body = body.concat(failure(throws)).concat([End]).concat(field(w, WasmGcTypePlan.arrayLengthFieldIndex())).concat([LocalSet(size),
			LocalGet(1), I32Const(0), I32LtS, LocalGet(size), LocalGet(1), I32LeS, I32Or, If(null)]).concat(failure(throws)).concat([End,
			LocalGet(1), LocalSet(cursor), Block(null), Loop(null), LocalGet(cursor), LocalGet(size), I32Const(1), I32Sub, I32Eq, BrIf(1),
			LocalGet(0), LocalGet(cursor), LocalGet(0), LocalGet(cursor), I32Const(1), I32Add, Call(move),
			LocalGet(cursor), I32Const(1), I32Add, LocalSet(cursor), Br(0), End, End,
			LocalGet(0), LocalGet(size), I32Const(1), I32Sub, Call(resize), Return]);
		return new WasmFunction(native.name, plan.wasmFunctionType(native.arguments, native.result), [{type:I32}, {type:I32}], body);
	}

	/** Resolve only forwarding headers; ordinary arrays and direct inline wrappers are left unchanged. */
	public static function resolveForward(plan:WasmGcTypePlan, array:Int):Array<WasmInstruction> {
		var wrapper = plan.valueArrayWrapperTypeIndex, base = plan.arrayType(plan.arrayElementTypes()[0]), marker = plan.valueArrayForwardLaneTypeIndex;
		return [LocalGet(array), RefIsNull, I32Eqz, LocalGet(array), RefTest({nullable:false, heap:Type(wrapper)}), I32Eqz, I32And, If(null),
			LocalGet(array), StructGet(base, WasmGcTypePlan.arrayDataFieldIndex()), RefTest({nullable:false, heap:Type(marker)}), If(null),
			LocalGet(array), StructGet(base, WasmGcTypePlan.arrayDataFieldIndex()), RefCast({nullable:false, heap:Type(marker)}), I32Const(0),
			ArrayGet(marker), RefCast({nullable:false, heap:Type(wrapper)}), LocalSet(array), End, End];
	}

	/** Length is the only mutable wrapper field read without going through the value-array runtime. */
	static function syncForwardLength(plan:WasmGcTypePlan):Array<WasmInstruction> {
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
			acceptSignature = module.typeIndex(plan.wasmFunctionType([Dyn], Bool)), writeSignature = module.typeIndex(plan.wasmFunctionType([Array(Dyn),I32,Dyn], Void));
		var body:Array<WasmInstruction> = [LocalGet(0), RefIsNull, If(null), LocalGet(0), Return, End, LocalGet(0), LocalSet(resolved)]
			.concat(resolveForward(plan, resolved)).concat([LocalGet(resolved), RefTest({nullable:false, heap:Type(w)}), If(null)]);
		for (pair in [{field:WasmGcTypePlan.arrayElementTypeFieldIndex(), arg:1}, {field:WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD, arg:2},
				{field:WasmGcTypePlan.VALUE_ARRAY_REFERENCE_STRIDE_FIELD, arg:3}, {field:WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD, arg:4},
				{field:WasmGcTypePlan.VALUE_ARRAY_VALIDITY_FIELD, arg:5}])
			body = body.concat(fieldAt(w, pair.field, resolved)).concat([LocalGet(pair.arg), I32Eq, I32Eqz, If(null)]).concat(failure(throws)).concat([End]);
		body = body.concat([LocalGet(0), Return, End]);
		// Only a dynamic backing lane may be converted here; validation precedes every mutation of the original header.
		body = body.concat(fieldAt(base, WasmGcTypePlan.arrayElementTypeFieldIndex(), 0))
			.concat([I32Const(plan.runtimeTypeIds.id(Dyn)), I32Eqz, If(null)]).concat(failure(throws)).concat([End]);
		// A header alone is not proof that its backing lane contains Dynamic values.
		// Check before ref.cast so an incompatible concrete reference array raises a language exception.
		body = body.concat(fieldAt(base, WasmGcTypePlan.arrayDataFieldIndex(), 0))
			.concat([RefTest({nullable:false, heap:Type(storage)}), I32Eqz, If(null)]).concat(failure(throws)).concat([End]);
		for (i in [6, 7, 8]) body = body.concat([LocalGet(i), RefIsNull, If(null)]).concat(failure(throws)).concat([End]);
		body = body.concat(fieldAt(base, WasmGcTypePlan.arrayLengthFieldIndex(), 0)).concat([LocalSet(length), Block(null), Loop(null),
			LocalGet(index), LocalGet(length), I32Eq, BrIf(1), LocalGet(0), StructGet(base, WasmGcTypePlan.arrayDataFieldIndex()),
			RefCast({nullable:false, heap:Type(storage)}), LocalGet(index), ArrayGet(storage), LocalSet(item), LocalGet(item),
			LocalGet(8), RefCast({nullable:false, heap:Type(plan.closureTypeIndex)}), StructGet(plan.closureTypeIndex, 0), I32Const(1), I32ShrU,
			CallIndirect(acceptSignature), I32Eqz, If(null)]).concat(failure(throws)).concat([End, LocalGet(index), I32Const(1), I32Add, LocalSet(index), Br(0), End, End,
			LocalGet(length), LocalGet(1), LocalGet(2), LocalGet(3), LocalGet(4), LocalGet(5), Call(allocator), LocalSet(candidate)]);
		for (pair in [{field:WasmGcTypePlan.VALUE_ARRAY_READ_BRIDGE_FIELD, arg:6}, {field:WasmGcTypePlan.VALUE_ARRAY_WRITE_BRIDGE_FIELD, arg:7},
				{field:WasmGcTypePlan.VALUE_ARRAY_ACCEPTS_BRIDGE_FIELD, arg:8}])
			body = body.concat([LocalGet(candidate), RefCast({nullable:false, heap:Type(w)}), LocalGet(pair.arg), StructSet(w, pair.field)]);
		body = body.concat([I32Const(0), LocalSet(index), Block(null), Loop(null), LocalGet(index), LocalGet(length), I32Eq, BrIf(1),
			LocalGet(candidate), LocalGet(index), LocalGet(0), StructGet(base, WasmGcTypePlan.arrayDataFieldIndex()), RefCast({nullable:false, heap:Type(storage)}),
			LocalGet(index), ArrayGet(storage), LocalGet(7), RefCast({nullable:false, heap:Type(plan.closureTypeIndex)}),
			StructGet(plan.closureTypeIndex, 0), I32Const(1), I32ShrU, CallIndirect(writeSignature),
			LocalGet(index), I32Const(1), I32Add, LocalSet(index), Br(0), End, End,
			I32Const(1), ArrayNewDefault(marker), LocalSet(forward), LocalGet(forward), RefCast({nullable:false, heap:Type(marker)}), I32Const(0), LocalGet(candidate),
			RefCast({nullable:false, heap:Type(w)}), ArraySet(marker), LocalGet(candidate), RefCast({nullable:false, heap:Type(w)}),
			LocalGet(0), StructSet(w, WasmGcTypePlan.VALUE_ARRAY_FORWARD_HEADER_FIELD), LocalGet(0), LocalGet(forward), RefCast({nullable:false, heap:Type(marker)}),
			StructSet(base, WasmGcTypePlan.arrayDataFieldIndex()), LocalGet(0), LocalGet(1), StructSet(base, WasmGcTypePlan.arrayElementTypeFieldIndex()),
			LocalGet(0), Return]);
		return new WasmFunction(native.name, plan.wasmFunctionType(native.arguments, native.result), [
			{type:I32}, {type:I32}, {type:plan.valueType(Array(Dyn))}, {type:Ref({nullable:true, heap:Type(marker)})},
			{type:plan.valueType(Dyn)}, {type:plan.valueType(Array(Dyn))}], body);
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
		body = body.concat([LocalGet(0), LocalGet(position), LocalGet(staged), I32Const(0), Call(move), Return]);
		var name = insert >= 0 ? "$value-array:runtime:insert-value" : "$value-array:runtime:store-value";
		return new WasmFunction(name, plan.wasmFunctionType([Array(Dyn),I32,Dyn], Void),
			[{type:plan.valueType(Array(Dyn))}, {type:Ref({nullable:true, heap:Type(plan.closureTypeIndex)})}, {type:I32}], body);
	}

	static function splice(plan:WasmGcTypePlan, native:IrNative, throws:Bool, newLike:Int, move:Int, resize:Int):WasmFunction {
		if (native.arguments.length != 3 || newLike < 0 || move < 0 || resize < 0) throw "Invalid Wasm GC value-array splice";
		var w = plan.valueArrayWrapperTypeIndex, size = 3, cursor = 4, result = 5;
		var body:Array<WasmInstruction> = [LocalGet(0), RefIsNull, If(null)];
		body = body.concat(failure(throws)).concat([End]).concat(field(w, WasmGcTypePlan.arrayLengthFieldIndex())).concat([LocalSet(size),
			LocalGet(2), I32Const(0), I32LtS, LocalGet(size), LocalGet(1), I32LtS, I32Or, If(null), LocalGet(0), I32Const(0), Call(newLike), Return, End,
			LocalGet(1), I32Const(0), I32LtS, If(null), LocalGet(1), LocalGet(size), I32Add, LocalSet(1),
				LocalGet(1), I32Const(0), I32LtS, If(null), I32Const(0), LocalSet(1), End, End,
			LocalGet(size), LocalGet(1), I32Sub, LocalGet(2), I32LtS, If(null), LocalGet(size), LocalGet(1), I32Sub, LocalSet(2), End,
			LocalGet(0), LocalGet(2), Call(newLike), LocalSet(result), Block(null), Loop(null), LocalGet(cursor), LocalGet(2), I32Eq, BrIf(1),
			LocalGet(result), LocalGet(cursor), LocalGet(0), LocalGet(1), LocalGet(cursor), I32Add, Call(move),
			LocalGet(cursor), I32Const(1), I32Add, LocalSet(cursor), Br(0), End, End,
			I32Const(0), LocalSet(cursor), Block(null), Loop(null), LocalGet(cursor), LocalGet(size), LocalGet(1), I32Sub, LocalGet(2), I32Sub, I32Eq, BrIf(1),
			LocalGet(0), LocalGet(1), LocalGet(cursor), I32Add, LocalGet(0), LocalGet(1), LocalGet(2), I32Add, LocalGet(cursor), I32Add, Call(move),
			LocalGet(cursor), I32Const(1), I32Add, LocalSet(cursor), Br(0), End, End,
			LocalGet(0), LocalGet(size), LocalGet(2), I32Sub, Call(resize), LocalGet(result), Return]);
		return new WasmFunction(native.name, plan.wasmFunctionType(native.arguments, native.result),
			[{type:I32}, {type:I32}, {type:plan.valueType(Array(Dyn))}], body);
	}

	static function concat(plan:WasmGcTypePlan, native:IrNative, throws:Bool, newLike:Int, move:Int):WasmFunction {
		if (native.arguments.length != 2 || newLike < 0 || move < 0) throw "Invalid Wasm GC value-array concat";
		var w = plan.valueArrayWrapperTypeIndex, leftSize = 2, rightSize = 3, cursor = 4, result = 5;
		var body:Array<WasmInstruction> = [LocalGet(0), RefIsNull, LocalGet(1), RefIsNull, I32Or, If(null)];
		body = body.concat(failure(throws)).concat([End]);
		for (index in [WasmGcTypePlan.arrayElementTypeFieldIndex(), WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD,
				WasmGcTypePlan.VALUE_ARRAY_REFERENCE_STRIDE_FIELD, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD, WasmGcTypePlan.VALUE_ARRAY_VALIDITY_FIELD])
			body = body.concat(fieldAt(w, index, 0)).concat(fieldAt(w, index, 1)).concat([I32Eq, I32Eqz, If(null)]).concat(failure(throws)).concat([End]);
		body = body.concat(fieldAt(w, WasmGcTypePlan.arrayLengthFieldIndex(), 0)).concat([LocalSet(leftSize)])
			.concat(fieldAt(w, WasmGcTypePlan.arrayLengthFieldIndex(), 1)).concat([LocalSet(rightSize),
				LocalGet(leftSize), I64ExtendI32U, LocalGet(rightSize), I64ExtendI32U, I64Add, I64Const(0x7fffffff), I64LeS, I32Eqz, If(null)])
			.concat(failure(throws)).concat([End, LocalGet(0), LocalGet(leftSize), LocalGet(rightSize), I32Add, Call(newLike), LocalSet(result)]);
		for (side in [{array:0, length:leftSize, offset:false}, {array:1, length:rightSize, offset:true}]) {
			body = body.concat([I32Const(0), LocalSet(cursor), Block(null), Loop(null), LocalGet(cursor), LocalGet(side.length), I32Eq, BrIf(1),
				LocalGet(result), LocalGet(cursor)]);
			if (side.offset) body = body.concat([LocalGet(leftSize), I32Add]);
			body = body.concat([LocalGet(side.array), LocalGet(cursor), Call(move), LocalGet(cursor), I32Const(1), I32Add, LocalSet(cursor), Br(0), End, End]);
		}
		body = body.concat([LocalGet(result), Return]);
		return new WasmFunction(native.name, plan.wasmFunctionType(native.arguments, native.result),
			[{type:I32}, {type:I32}, {type:I32}, {type:plan.valueType(Array(Dyn))}], body);
	}

	/** Allocate the same lane layout and retain the shared dynamic bridge closures. */
	static function newLike(plan:WasmGcTypePlan, allocator:Int):WasmFunction {
		var w = plan.valueArrayWrapperTypeIndex, result = 2;
		var body:Array<WasmInstruction> = [LocalGet(1)];
		for (index in [WasmGcTypePlan.arrayElementTypeFieldIndex(), WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD,
				WasmGcTypePlan.VALUE_ARRAY_REFERENCE_STRIDE_FIELD, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD, WasmGcTypePlan.VALUE_ARRAY_VALIDITY_FIELD])
			body = body.concat(field(w, index));
		body = body.concat([Call(allocator), LocalSet(result)]);
		for (index in [WasmGcTypePlan.VALUE_ARRAY_READ_BRIDGE_FIELD, WasmGcTypePlan.VALUE_ARRAY_WRITE_BRIDGE_FIELD, WasmGcTypePlan.VALUE_ARRAY_ACCEPTS_BRIDGE_FIELD])
			body = body.concat([LocalGet(result), RefCast({nullable:false, heap:Type(w)})]).concat(field(w, index)).concat([StructSet(w, index)]);
		body = body.concat([LocalGet(result), Return]);
		return new WasmFunction("$value-array:internal:new-like", plan.wasmFunctionType([Array(Dyn),I32], Array(Dyn)), [{type:plan.valueType(Array(Dyn))}], body);
	}

	static function rangeCopy(plan:WasmGcTypePlan, native:IrNative, throws:Bool, newLike:Int, move:Int):WasmFunction {
		var slice = native.symbol == "__value_array_slice";
		if (native.arguments.length != (slice ? 3 : 1) || newLike < 0 || move < 0) throw "Invalid Wasm GC value-array range copy";
		var w = plan.valueArrayWrapperTypeIndex, first = native.arguments.length, start = first, end = first + 1, size = first + 2,
			cursor = first + 3, result = first + 4;
		var body:Array<WasmInstruction> = [LocalGet(0), RefIsNull, If(null)];
		body = body.concat(failure(throws)).concat([End]).concat(field(w, WasmGcTypePlan.arrayLengthFieldIndex())).concat([LocalSet(size)]);
		if (slice) {
			for (pair in [{arg:1, dest:start}, {arg:2, dest:end}]) body = body.concat([LocalGet(pair.arg), LocalSet(pair.dest),
				LocalGet(pair.dest), I32Const(0), I32LtS, If(null), LocalGet(pair.dest), LocalGet(size), I32Add, LocalSet(pair.dest), End,
				LocalGet(pair.dest), I32Const(0), I32LtS, If(null), I32Const(0), LocalSet(pair.dest), End,
				LocalGet(size), LocalGet(pair.dest), I32LtS, If(null), LocalGet(size), LocalSet(pair.dest), End]);
			body = body.concat([LocalGet(end), LocalGet(start), I32LtS, If(null), LocalGet(start), LocalSet(end), End]);
		} else body = body.concat([I32Const(0), LocalSet(start), LocalGet(size), LocalSet(end)]);
		body = body.concat([LocalGet(0), LocalGet(end), LocalGet(start), I32Sub, Call(newLike), LocalSet(result),
			Block(null), Loop(null), LocalGet(cursor), LocalGet(end), LocalGet(start), I32Sub, I32Eq, BrIf(1),
			LocalGet(result), LocalGet(cursor), LocalGet(0), LocalGet(start), LocalGet(cursor), I32Add, Call(move),
			LocalGet(cursor), I32Const(1), I32Add, LocalSet(cursor), Br(0), End, End, LocalGet(result), Return]);
		return new WasmFunction(native.name, plan.wasmFunctionType(native.arguments, native.result),
			[{type:I32}, {type:I32}, {type:I32}, {type:I32}, {type:plan.valueType(Array(Dyn))}], body);
	}

	/** Move one already-bounded element between compatible arrays, preserving uninitialized elements. */
	static function moveElement(plan:WasmGcTypePlan, read:Int, write:Int, readRef:Int, writeRef:Int, valid:Int, mark:Int, clear:Int):WasmFunction {
		var w = plan.valueArrayWrapperTypeIndex, offset = 4;
		var body:Array<WasmInstruction> = [LocalGet(2), LocalGet(3), Call(valid), I32Eqz, If(null), LocalGet(0), LocalGet(1), Call(clear), Return, End,
			Block(null), Loop(null), LocalGet(offset)];
		body = body.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD)).concat([I32Eq, BrIf(1),
			LocalGet(0), LocalGet(1), LocalGet(offset), I32Const(8), LocalGet(2), LocalGet(3), LocalGet(offset), I32Const(8), I32Const(0), Call(read), Call(write),
			LocalGet(offset), I32Const(8), I32Add, LocalSet(offset), Br(0), End, End,
			I32Const(0), LocalSet(offset), Block(null), Loop(null), LocalGet(offset)])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_STRIDE_FIELD)).concat([I32Eq, BrIf(1),
				LocalGet(0), LocalGet(1), LocalGet(offset), LocalGet(2), LocalGet(3), LocalGet(offset), Call(readRef), Call(writeRef),
				LocalGet(offset), I32Const(1), I32Add, LocalSet(offset), Br(0), End, End, LocalGet(0), LocalGet(1), Call(mark), Return]);
		return new WasmFunction("$value-array:internal:move-element", plan.wasmFunctionType([Array(Dyn),I32,Array(Dyn),I32], Void), [{type:I32}], body);
	}

	/** Swap in place without a boxed temporary or an allocated staging array. */
	static function swapElements(plan:WasmGcTypePlan, read:Int, write:Int, readRef:Int, writeRef:Int, valid:Int, mark:Int, clear:Int):WasmFunction {
		var w = plan.valueArrayWrapperTypeIndex, offset = 3, leftValid = 4, rightValid = 5, leftByte = 6, rightByte = 7, leftRef = 8, rightRef = 9;
		var refType:WasmValueType = Ref({nullable:true, heap:Any});
		var locals:Array<WasmLocal> = [{type:I32}, {type:I32}, {type:I32}, {type:I32}, {type:I32}, {type:refType}, {type:refType}];
		var body:Array<WasmInstruction> = [LocalGet(0), LocalGet(1), Call(valid), LocalSet(leftValid), LocalGet(0), LocalGet(2), Call(valid), LocalSet(rightValid),
			Block(null), Loop(null), LocalGet(offset)];
		body = body.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD)).concat([I32Eq, BrIf(1)]);
		for (side in [{valid:leftValid, index:1, dest:leftByte}, {valid:rightValid, index:2, dest:rightByte}])
			body = body.concat([LocalGet(side.valid), If(I32), LocalGet(0), LocalGet(side.index), LocalGet(offset), I32Const(8), I32Const(0), Call(read),
				Else, I32Const(0), End, LocalSet(side.dest)]);
		body = body.concat([LocalGet(0), LocalGet(1), LocalGet(offset), I32Const(8), LocalGet(rightByte), Call(write),
			LocalGet(0), LocalGet(2), LocalGet(offset), I32Const(8), LocalGet(leftByte), Call(write),
			LocalGet(offset), I32Const(8), I32Add, LocalSet(offset), Br(0), End, End,
			I32Const(0), LocalSet(offset), Block(null), Loop(null), LocalGet(offset)])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_STRIDE_FIELD)).concat([I32Eq, BrIf(1)]);
		for (side in [{valid:leftValid, index:1, dest:leftRef}, {valid:rightValid, index:2, dest:rightRef}])
			body = body.concat([LocalGet(side.valid), If(refType), LocalGet(0), LocalGet(side.index), LocalGet(offset), Call(readRef),
				Else, RefNull(Any), End, LocalSet(side.dest)]);
		body = body.concat([LocalGet(0), LocalGet(1), LocalGet(offset), LocalGet(rightRef), Call(writeRef),
			LocalGet(0), LocalGet(2), LocalGet(offset), LocalGet(leftRef), Call(writeRef),
			LocalGet(offset), I32Const(1), I32Add, LocalSet(offset), Br(0), End, End]);
		for (side in [{valid:rightValid, index:1}, {valid:leftValid, index:2}])
			body = body.concat([LocalGet(side.valid), If(null), LocalGet(0), LocalGet(side.index), Call(mark), Else,
				LocalGet(0), LocalGet(side.index), Call(clear), End]);
		body.push(Return);
		return new WasmFunction("$value-array:internal:swap-elements", plan.wasmFunctionType([Array(Dyn),I32,I32], Void), locals, body);
	}

	static function reverse(plan:WasmGcTypePlan, native:IrNative, throws:Bool, swap:Int):WasmFunction {
		if (native.arguments.length != 1 || swap < 0) throw "Invalid Wasm GC value-array reverse";
		var w = plan.valueArrayWrapperTypeIndex, left = 1, right = 2;
		var body:Array<WasmInstruction> = [LocalGet(0), RefIsNull, If(null)];
		body = body.concat(failure(throws)).concat([End]).concat(field(w, WasmGcTypePlan.arrayLengthFieldIndex()))
			.concat([I32Const(1), I32Sub, LocalSet(right), Block(null), Loop(null), LocalGet(left), LocalGet(right), I32LtS, I32Eqz, BrIf(1),
				LocalGet(0), LocalGet(left), LocalGet(right), Call(swap), LocalGet(left), I32Const(1), I32Add, LocalSet(left),
				LocalGet(right), I32Const(1), I32Sub, LocalSet(right), Br(0), End, End, Return]);
		return new WasmFunction(native.name, plan.wasmFunctionType(native.arguments, native.result), [{type:I32}, {type:I32}], body);
	}

	static function insertEmpty(plan:WasmGcTypePlan, native:IrNative, throws:Bool, ensure:Int, clear:Int, move:Int):WasmFunction {
		if (native.arguments.length != 2 || ensure < 0 || clear < 0 || move < 0) throw "Invalid Wasm GC value-array insertion";
		var w = plan.valueArrayWrapperTypeIndex, size = 2, cursor = 3;
		var body:Array<WasmInstruction> = [LocalGet(0), RefIsNull, If(null)];
		body = body.concat(failure(throws)).concat([End]).concat(field(w, WasmGcTypePlan.arrayLengthFieldIndex()))
			.concat([LocalTee(size), I32Const(0x7fffffff), I32Eq, If(null)]).concat(failure(throws)).concat([End,
				LocalGet(1), I32Const(0), I32LtS, If(null), LocalGet(1), LocalGet(size), I32Add, LocalSet(1), End,
				LocalGet(1), I32Const(0), I32LtS, If(null), I32Const(0), LocalSet(1), End,
				LocalGet(size), LocalGet(1), I32LtS, If(null), LocalGet(size), LocalSet(1), End,
				LocalGet(0), LocalGet(size), Call(ensure), LocalGet(size), LocalSet(cursor), Block(null), Loop(null),
				LocalGet(cursor), LocalGet(1), I32LeS, BrIf(1), LocalGet(0), LocalGet(cursor), LocalGet(0), LocalGet(cursor), I32Const(1), I32Sub, Call(move),
				LocalGet(cursor), I32Const(1), I32Sub, LocalSet(cursor), Br(0), End, End,
				LocalGet(0), LocalGet(1), Call(clear), LocalGet(1), Return]);
		return new WasmFunction(native.name, plan.wasmFunctionType(native.arguments, native.result), [{type:I32}, {type:I32}], body);
	}

	static function resize(plan:WasmGcTypePlan, native:IrNative, throws:Bool, ensureIndex:Int, clearIndex:Int):WasmFunction {
		if (native.arguments.length != 2 || ensureIndex < 0 || clearIndex < 0) throw "Invalid Wasm GC value-array resize";
		var w = plan.valueArrayWrapperTypeIndex, cursor = 2;
		var body:Array<WasmInstruction> = [LocalGet(0), RefIsNull, LocalGet(1), I32Const(0), I32LtS, I32Or, If(null)];
		body = body.concat(failure(throws)).concat([End]);
		body = body.concat(field(w, WasmGcTypePlan.arrayLengthFieldIndex())).concat([LocalSet(cursor), LocalGet(1), LocalGet(cursor), I32LeS,
			I32Eqz, If(null), LocalGet(0), LocalGet(1), I32Const(1), I32Sub, Call(ensureIndex), Return, End,
			Block(null), Loop(null), LocalGet(cursor), LocalGet(1), I32LeS, BrIf(1), LocalGet(cursor), I32Const(1), I32Sub, LocalSet(cursor),
			LocalGet(0), LocalGet(cursor), Call(clearIndex), Br(0), End, End,
			LocalGet(0), RefCast({nullable:false, heap:Type(w)}), LocalGet(1), StructSet(w, WasmGcTypePlan.arrayLengthFieldIndex())])
			.concat(syncForwardLength(plan)).concat([Return]);
		return new WasmFunction(native.name, plan.wasmFunctionType(native.arguments, native.result), [{type:I32}], body);
	}

	/** Grow both lanes before publishing either one so allocation failure leaves aliases unchanged. */
	static function ensure(plan:WasmGcTypePlan, native:IrNative, throws:Bool):WasmFunction {
		if (native.arguments.length != 2) throw "Invalid Wasm GC value-array ensure";
		var w = plan.valueArrayWrapperTypeIndex, l32 = plan.valueArrayI32LaneTypeIndex, l64 = plan.valueArrayI64LaneTypeIndex,
			refs = plan.valueArrayReferenceLaneTypeIndex, oldCap = 2, newCap = 3, oldPayload = 4, newPayload = 5,
			bitmap = 6, refCount = 7, total = 8, oldData = 9, newData = 10, oldRef = 11, newRef = 12;
		var arrayType:WasmValueType = Ref({nullable:true, heap:Array});
		var locals:Array<WasmLocal> = [{type:I32}, {type:I32}, {type:I32}, {type:I32}, {type:I32}, {type:I32}, {type:I64},
			{type:arrayType}, {type:arrayType}, {type:arrayType}, {type:arrayType}];
		var body:Array<WasmInstruction> = [LocalGet(0), RefIsNull, If(null)];
		body = body.concat(failure(throws)).concat([End, LocalGet(1), I32Const(0), I32LtS, LocalGet(1), I32Const(0x7fffffff), I32Eq, I32Or, If(null)])
			.concat(failure(throws)).concat([End]);
		body = body.concat(field(w, WasmGcTypePlan.arrayLengthFieldIndex())).concat([LocalGet(1), I32LeS, I32Eqz, If(null), Return, End])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_CAPACITY_FIELD)).concat([LocalSet(oldCap), LocalGet(1), LocalGet(oldCap), I32LeS,
				LocalGet(1), LocalGet(oldCap), I32Eq, I32Eqz, I32And, If(null)])
			.concat([LocalGet(0), RefCast({nullable:false, heap:Type(w)}), LocalGet(1), I32Const(1), I32Add,
				StructSet(w, WasmGcTypePlan.arrayLengthFieldIndex())]).concat(syncForwardLength(plan)).concat([Return, End]);
		// Grow by at least half, or directly to the requested index for sparse writes.
		body = body.concat([LocalGet(oldCap), I64ExtendI32U, LocalGet(oldCap), I32Const(2), I32DivS, I64ExtendI32U, I64Add, LocalSet(total),
			LocalGet(total), I64Const(0x7fffffff), I64LeS, I32Eqz, If(null), LocalGet(1), I32Const(1), I32Add, LocalSet(newCap), Else,
			LocalGet(total), I32WrapI64, LocalGet(1), I32Const(1), I32Add, I32LeS, If(null), LocalGet(1), I32Const(1), I32Add,
			LocalSet(newCap), Else, LocalGet(total), I32WrapI64, LocalSet(newCap), End, End]);
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
			StructSet(w, WasmGcTypePlan.VALUE_ARRAY_CAPACITY_FIELD), LocalGet(0), RefCast({nullable:false, heap:Type(w)}), LocalGet(1), I32Const(1),
			I32Add, StructSet(w, WasmGcTypePlan.arrayLengthFieldIndex())]).concat(syncForwardLength(plan)).concat([Return]);
		return new WasmFunction(native.name, plan.wasmFunctionType(native.arguments, native.result), locals, body);
	}

	/** Index of the element's bitmap word, following the capacity-sized payload. */
	static function bitmapWordIndex(wrapper:Int):Array<WasmInstruction> {
		var bits = field(wrapper, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD);
		return field(wrapper, WasmGcTypePlan.VALUE_ARRAY_CAPACITY_FIELD).concat([I64ExtendI32U])
			.concat(field(wrapper, WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD)).concat([I64ExtendI32U, I64Mul])
			.concat(bits).concat([I64ExtendI32U, I64Const(1), I64Sub, I64Add])
			.concat(bits).concat([I64ExtendI32U, I64DivS, LocalGet(1), I64ExtendI32U])
			.concat(bits).concat([I64ExtendI32U, I64DivS, I64Add, I32WrapI64]);
	}

	static function bitmapBit(wrapper:Int):Array<WasmInstruction>
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

	/** Clear payload and references without touching neighboring packed elements. */
	static function clearElement(plan:WasmGcTypePlan, native:IrNative, throws:Bool):WasmFunction {
		if (native.arguments.length != 2) throw "Invalid Wasm GC value-array clear";
		var w = plan.valueArrayWrapperTypeIndex, l32 = plan.valueArrayI32LaneTypeIndex, l64 = plan.valueArrayI64LaneTypeIndex,
			refs = plan.valueArrayReferenceLaneTypeIndex, position = 2, wordIndex = 3, shift = 4, address = 5, refLane = 6;
		var locals:Array<WasmLocal> = [{type:I32}, {type:I32}, {type:I32}, {type:I64}, {type:Ref({nullable:true, heap:Type(refs)})}];
		var body:Array<WasmInstruction> = [LocalGet(0), RefIsNull, If(null)];
		body = body.concat(failure(throws)).concat([End, LocalGet(1), I32Const(0), I32LtS]);
		body = body.concat(field(w, WasmGcTypePlan.arrayLengthFieldIndex())).concat([LocalGet(1), I32LeS, I32Or, If(null)]);
		body = body.concat(failure(throws)).concat([End]);
		// Each scalar stride is byte-aligned; clear one byte at a time to retain adjacent elements.
		body = body.concat([LocalGet(1), I64ExtendI32U]).concat(field(w, WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD))
			.concat([I64ExtendI32U, I64Mul, LocalSet(address), Block(null), Loop(null), LocalGet(position)])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD)).concat([I32Const(8), I32DivS, I32Eq, BrIf(1),
				LocalGet(address), LocalGet(position), I64ExtendI32U, I64Const(8), I64Mul, I64Add])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD)).concat([I64ExtendI32U, I64DivS, I32WrapI64, LocalSet(wordIndex),
				LocalGet(address), LocalGet(position), I64ExtendI32U, I64Const(8), I64Mul, I64Add])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD)).concat([I64ExtendI32U, I64RemS, I32WrapI64, LocalSet(shift)])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD)).concat([I32Const(32), I32Eq, If(null)]);
		for (lane in [l32, l64]) {
			body = body.concat(field(w, WasmGcTypePlan.arrayDataFieldIndex())).concat([RefCast({nullable:false, heap:Type(lane)}), LocalGet(wordIndex)])
				.concat(field(w, WasmGcTypePlan.arrayDataFieldIndex())).concat([RefCast({nullable:false, heap:Type(lane)}), LocalGet(wordIndex), ArrayGet(lane)]);
			if (lane == l32) body.push(I64ExtendI32U);
			body = body.concat([I64Const(255), LocalGet(shift), I64ExtendI32U, I64Shl, I64Const(-1), I64Xor, I64And]);
			if (lane == l32) body.push(I32WrapI64);
			body.push(ArraySet(lane));
			if (lane == l32) body.push(Else);
		}
		body = body.concat([End, LocalGet(position), I32Const(1), I32Add, LocalSet(position), Br(0), End, End]);
		// Select the sole reference lane or the optional mixed lane; absent mixed lanes need no allocation.
		body = body.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_STRIDE_FIELD)).concat([If(null)])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD)).concat([I32Eqz])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_VALIDITY_FIELD)).concat([I32Eqz, I32And, If(null)])
			.concat(field(w, WasmGcTypePlan.arrayDataFieldIndex())).concat([RefCast({nullable:false, heap:Type(refs)}), LocalSet(refLane), Else])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_FIELD)).concat([RefCast({nullable:true, heap:Type(refs)}), LocalSet(refLane), End,
				LocalGet(refLane), RefIsNull, I32Eqz, If(null), I32Const(0), LocalSet(position), Block(null), Loop(null), LocalGet(position)])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_STRIDE_FIELD)).concat([I32Eq, BrIf(1), LocalGet(refLane),
				RefCast({nullable:false, heap:Type(refs)}), LocalGet(1)])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_REFERENCE_STRIDE_FIELD)).concat([I32Mul, LocalGet(position), I32Add, RefNull(Any), ArraySet(refs),
				LocalGet(position), I32Const(1), I32Add, LocalSet(position), Br(0), End, End, End, End]);
		// Clear the validity bit after the payload and references.
		body = body.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_VALIDITY_FIELD)).concat([If(null)])
			.concat(field(w, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD)).concat([I32Const(32), I32Eq, If(null)]);
		for (lane in [l32, l64]) {
			body = body.concat(field(w, WasmGcTypePlan.arrayDataFieldIndex())).concat([RefCast({nullable:false, heap:Type(lane)})])
				.concat(bitmapWordIndex(w)).concat(field(w, WasmGcTypePlan.arrayDataFieldIndex()))
				.concat([RefCast({nullable:false, heap:Type(lane)})]).concat(bitmapWordIndex(w)).concat([ArrayGet(lane)]);
			if (lane == l32) body.push(I64ExtendI32U);
			body = body.concat([I64Const(1)]).concat(bitmapBit(w)).concat([I64Shl, I64Const(-1), I64Xor, I64And]);
			if (lane == l32) body.push(I32WrapI64);
			body.push(ArraySet(lane));
			if (lane == l32) body.push(Else);
		}
		body = body.concat([End, End, Return]);
		return new WasmFunction(native.name, plan.wasmFunctionType(native.arguments, native.result), locals, body);
	}

	static function allocate(plan:WasmGcTypePlan, native:IrNative, throws:Bool):WasmFunction {
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

	/** Copy bytes through the packed word lane; bytes may cross either kind of word boundary. */
	static function scalarSlot(plan:WasmGcTypePlan, native:IrNative, throws:Bool):WasmFunction {
		var name = native.symbol, clear = name == "__value_array_clear_scalar", write = clear || StringTools.startsWith(name, "__value_array_write_");
		var suffix = clear ? "clear" : name.substr(write ? "__value_array_write_".length : "__value_array_read_".length);
		var integer = suffix == "i32" || suffix == "i64";
		var variableWidth = integer || suffix == "ptr" || suffix == "type" || clear;
		var expected = 3 + (variableWidth ? 1 : 0) + (write && !clear ? 1 : 0) + (!write && integer ? 1 : 0);
		if (native.arguments.length != expected) throw 'Invalid Wasm GC value-array scalar access: $name';
		var first = native.arguments.length, width = first, wordBits = first + 1, byteIndex = first + 2,
			wordIndex = first + 3, shift = first + 4, address = first + 5, bits = first + 6, word = first + 7,
			wrapper = plan.valueArrayWrapperTypeIndex, lane32 = plan.valueArrayI32LaneTypeIndex, lane64 = plan.valueArrayI64LaneTypeIndex;
		var locals:Array<WasmLocal> = [{type:I32}, {type:I32}, {type:I32}, {type:I32}, {type:I32}, {type:I64}, {type:I64}, {type:I64}];
		var body:Array<WasmInstruction> = [LocalGet(0), RefIsNull, If(null)];
		body = body.concat(failure(throws)).concat([End]);
		body.push(variableWidth ? LocalGet(3) : I32Const(suffix == "bool" ? 8 : suffix == "f32" || suffix == "callback" ? 32 : 64));
		body.push(LocalSet(width));
		// Check the same byte alignment, width, and logical bounds as the native implementation.
		body = body.concat([LocalGet(1), I32Const(0), I32LtS, LocalGet(0), RefCast({nullable:false, heap:Type(wrapper)}),
			StructGet(wrapper, WasmGcTypePlan.arrayLengthFieldIndex()), LocalGet(1), I32LeS, I32Or,
			LocalGet(2), I32Const(0), I32LtS, I32Or, LocalGet(2), I32Const(7), I32And, I32Or,
			LocalGet(width), I32Const(8), I32Eq, LocalGet(width), I32Const(16), I32Eq, I32Or,
			LocalGet(width), I32Const(32), I32Eq, I32Or, LocalGet(width), I32Const(64), I32Eq, I32Or, I32Eqz, I32Or,
			LocalGet(2), I64ExtendI32S, LocalGet(width), I64ExtendI32S, I64Add,
			LocalGet(0), RefCast({nullable:false, heap:Type(wrapper)}), StructGet(wrapper, WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD),
			I64ExtendI32U, I64LeS, I32Eqz, I32Or]);
		if (suffix == "i32") body = body.concat([LocalGet(width), I32Const(32), I32LeS, I32Eqz, I32Or]);
		if (suffix == "ptr" || suffix == "type") body = body.concat([LocalGet(width), I32Const(32), I32Eq, I32Eqz, I32Or]);
		body.push(If(null)); body = body.concat(failure(throws)).concat([End]);
		if (!write) body = body.concat(initialized(plan)).concat([I32Eqz, If(null)]).concat(failure(throws)).concat([End]);
		body = body.concat([LocalGet(0), RefCast({nullable:false, heap:Type(wrapper)}),
			StructGet(wrapper, WasmGcTypePlan.VALUE_ARRAY_WORD_BITS_FIELD), LocalSet(wordBits),
			LocalGet(1), I64ExtendI32U, LocalGet(0), RefCast({nullable:false, heap:Type(wrapper)}),
			StructGet(wrapper, WasmGcTypePlan.VALUE_ARRAY_SCALAR_STRIDE_FIELD), I64ExtendI32U, I64Mul,
			LocalGet(2), I64ExtendI32U, I64Add, LocalSet(address)]);
		if (write && !clear) {
			body.push(LocalGet(variableWidth ? 4 : 3));
			body = body.concat(switch suffix {
				case "i32", "bool", "ptr", "type", "callback": [I64ExtendI32U];
				case "i64": [];
				case "f32": [F32DemoteF64, I32ReinterpretF32, I64ExtendI32U];
				case "f64": [I64ReinterpretF64];
				default: throw 'Unsupported Wasm GC scalar lane $suffix';
			});
			body.push(LocalSet(bits));
		}
		body = body.concat([Block(null), Loop(null), LocalGet(byteIndex), LocalGet(width), I32Const(8), I32DivS, I32Eq, BrIf(1)]);
		// Address and shift refer to this byte within the selected scalar word.
		body = body.concat([LocalGet(address), LocalGet(byteIndex), I64ExtendI32U, I64Const(8), I64Mul, I64Add,
			LocalGet(wordBits), I64ExtendI32U, I64DivS, I32WrapI64, LocalSet(wordIndex),
			LocalGet(address), LocalGet(byteIndex), I64ExtendI32U, I64Const(8), I64Mul, I64Add,
			LocalGet(wordBits), I64ExtendI32U, I64RemS, I32WrapI64, LocalSet(shift),
			LocalGet(wordBits), I32Const(32), I32Eq, If(I64), LocalGet(0), RefCast({nullable:false, heap:Type(wrapper)}),
			StructGet(wrapper, WasmGcTypePlan.arrayDataFieldIndex()), RefCast({nullable:false, heap:Type(lane32)}), LocalGet(wordIndex),
			ArrayGet(lane32), I64ExtendI32U, Else, LocalGet(0), RefCast({nullable:false, heap:Type(wrapper)}),
			StructGet(wrapper, WasmGcTypePlan.arrayDataFieldIndex()), RefCast({nullable:false, heap:Type(lane64)}), LocalGet(wordIndex), ArrayGet(lane64), End,
			LocalSet(word)]);
		if (write) {
			body = body.concat([LocalGet(word), I64Const(255), LocalGet(shift), I64ExtendI32U, I64Shl, I64Const(-1), I64Xor, I64And,
				LocalGet(bits), LocalGet(byteIndex), I64ExtendI32U, I64Const(8), I64Mul, I64ShrU, I64Const(255), I64And,
				LocalGet(shift), I64ExtendI32U, I64Shl, I64Or, LocalSet(word),
				LocalGet(wordBits), I32Const(32), I32Eq, If(null), LocalGet(0), RefCast({nullable:false, heap:Type(wrapper)}),
				StructGet(wrapper, WasmGcTypePlan.arrayDataFieldIndex()), RefCast({nullable:false, heap:Type(lane32)}), LocalGet(wordIndex),
				LocalGet(word), I32WrapI64, ArraySet(lane32), Else, LocalGet(0), RefCast({nullable:false, heap:Type(wrapper)}),
				StructGet(wrapper, WasmGcTypePlan.arrayDataFieldIndex()), RefCast({nullable:false, heap:Type(lane64)}), LocalGet(wordIndex),
				LocalGet(word), ArraySet(lane64), End]);
		} else body = body.concat([LocalGet(bits), LocalGet(word), LocalGet(shift), I64ExtendI32U, I64ShrU, I64Const(255), I64And,
			LocalGet(byteIndex), I64ExtendI32U, I64Const(8), I64Mul, I64Shl, I64Or, LocalSet(bits)]);
		body = body.concat([LocalGet(byteIndex), I32Const(1), I32Add, LocalSet(byteIndex), Br(0), End, End]);
		if (!write) {
			if (integer) body = body.concat([LocalGet(4), If(null), LocalGet(bits), I64Const(64), LocalGet(width), I64ExtendI32U,
				I64Sub, I64Shl, I64Const(64), LocalGet(width), I64ExtendI32U, I64Sub, I64ShrS, LocalSet(bits), End]);
			body.push(LocalGet(bits));
			body = body.concat(switch suffix {
				case "i32", "ptr", "type", "callback": [I32WrapI64];
				case "bool": [I64Eqz, I32Eqz];
				case "i64": [];
				case "f32": [I32WrapI64, F32ReinterpretI32, F64PromoteF32];
				case "f64": [F64ReinterpretI64];
				default: throw 'Unsupported Wasm GC scalar lane $suffix';
			});
		}
		body.push(Return);
		return new WasmFunction(native.name, plan.wasmFunctionType(native.arguments, native.result), locals, body);
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
