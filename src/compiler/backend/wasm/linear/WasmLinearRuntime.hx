package compiler.backend.wasm.linear;

import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmBackend;

class WasmLinearRuntime {
	public static function addImports(context:WasmLinearContext, used:Map<String, Bool>):Void {
		var module = context.module, program = context.program;
		for (native in program.natives)
			if (used.exists(native.name))
				switch native.symbol {
					case "__math_is_finite", "__math_pow", "__math_cos", "__math_sin", "__math_tan", "__math_fmod", "__math_round", "__math_ceil",
						"__sys_print", "__sys_args", "__date_now", "__date_get_time", "sys_time", "sys_cpu_time", "sys_thread_cpu_time", "sys_process_memory",
						"sys_getpid", "sys_sleep", "sys_get_char", "sys_exit":
						runtimeImport(module, native);
					default:
				}
	}

	public static function register(context:WasmLinearContext):Void
		addRuntimeFunctions(context);

	static function runtimeImport(module:WasmModule, native:compiler.ir.Ir.IrNative):Int {
		var existing = runtimeImportIndex(module, native);
		if (existing != null)
			return existing;
		var importModule = native.library == null || native.library == "" ? "env" : native.library,
			importName = native.symbol == null || native.symbol == "" ? native.name : native.symbol;
		return module.addImport(importModule, importName,
			{parameters: [for (argument in native.arguments) WasmBackend.requireValueType(argument)], results: resultTypes(native.result)});
	}

	static function runtimeImportIndex(module:WasmModule, native:compiler.ir.Ir.IrNative):Null<Int> {
		var importModule = native.library == null || native.library == "" ? "env" : native.library,
			importName = native.symbol == null || native.symbol == "" ? native.name : native.symbol;
		for (index in 0...module.imports.length) {
			var imported = module.imports[index];
			if (imported.module == importModule && imported.name == importName)
				return index;
		}
		return null;
	}

	static function addRuntimeFunctions(context:WasmLinearContext):Void {
		var module = context.module,
			functions = context.functions,
			program = context.program,
			allocator = context.allocatorFunction,
			strings = context.strings,
			ryuTableBase = context.ryuTableBase;
		for (native in program.natives) {
			var runtimeFunction = addRuntimeNativeFunction(module, native, allocator);
			if (runtimeFunction != null)
				functions.set(native.name, runtimeFunction);
			else {
				var mapParts = WasmBackend.mapNativeParts(native.name);
				if (mapParts != null)
					functions.set(native.name, addMapRuntimeFunction(module, functions, native.name, mapParts.mapName, mapParts.operation, allocator));
				else
					switch native.name {
						case "__string_length":
							functions.set(native.name,
								module.addFunction(new WasmFunction(native.name, {parameters: [I32], results: [I32]}, [],
									[LocalGet(0), I32Load(WasmLayout.STRING_LENGTH_OFFSET), Return])));
						case "__string_char_code_at":
							functions.set(native.name, addStringCharCodeAt(module, native.name));
						case "__string_concat":
							functions.set(native.name, addStringConcat(module, native.name, allocator));
						case "__string_equal":
							functions.set(native.name, addStringEqual(module, native.name));
						case "__string_compare_full":
							functions.set(native.name, addStringCompareFull(module, native.name));
						case "__std_int_f64":
							functions.set(native.name,
								module.addFunction(new WasmFunction(native.name, {parameters: [F64], results: [I32]}, [],
									[LocalGet(0), I32TruncF64S, Return])));
						case "__std_int_dynamic":
							functions.set(native.name, addDynamicInt(module, native.name));
						case "__reflect_is_object":
							functions.set(native.name, addDynamicIsObject(module, native.name, program));
						case "__std_string":
							functions.set(native.name, addDynamicString(module, native.name, allocator, strings, ryuTableBase));
						case "__dynamic_equal":
							// Emitted after the native scan so the string helper has an index.
						case "__std_is_of_type", "__exception_matches":
							functions.set(native.name, addTypeTest(module, native.name, program));
						case "__array_copy_i32", "__array_copy_bool", "__array_copy_ref", "__array_copy_bytes":
							functions.set(native.name, WasmLinearArrays.addArrayCopy(module, native.name, 4, allocator));
						case "__array_copy_f64":
							functions.set(native.name, WasmLinearArrays.addArrayCopy(module, native.name, 8, allocator));
						case "__array_index_of_i32", "__array_index_of_bool", "__array_index_of_ref":
							functions.set(native.name, WasmLinearArrays.addArrayIndexOf(module, native.name, 4, I32, null));
						case "__array_index_of_bytes":
							var stringEqual = functions.get("__string_equal");
							if (stringEqual == null) {
								stringEqual = addStringEqual(module, "__string_equal");
								functions.set("__string_equal", stringEqual);
							}
							functions.set(native.name, WasmLinearArrays.addArrayIndexOf(module, native.name, 4, I32, stringEqual));
						case "__array_index_of_f64":
							functions.set(native.name, WasmLinearArrays.addArrayIndexOf(module, native.name, 8, F64, null));
						case "__array_slice_i32", "__array_slice_bool", "__array_slice_ref", "__array_slice_bytes":
							functions.set(native.name, WasmLinearArrays.addArraySlice(module, native.name, 4, allocator));
						case "__array_slice_f64":
							functions.set(native.name, WasmLinearArrays.addArraySlice(module, native.name, 8, allocator));
						case "__array_join_bytes":
							var stringConcat = functions.get("__string_concat");
							if (stringConcat == null) {
								stringConcat = addStringConcat(module, "__string_concat", allocator);
								functions.set("__string_concat", stringConcat);
							}
							functions.set(native.name, WasmLinearArrays.addArrayJoinBytes(module, native.name, allocator, stringConcat));
						case "__array_concat_i32", "__array_concat_bool", "__array_concat_ref", "__array_concat_bytes":
							functions.set(native.name, WasmLinearArrays.addArrayConcat(module, native.name, 4, allocator));
						case "__array_concat_f64":
							functions.set(native.name, WasmLinearArrays.addArrayConcat(module, native.name, 8, allocator));
						case "__array_push_i32", "__array_push_bool", "__array_push_ref", "__array_push_bytes":
							functions.set(native.name, WasmLinearArrays.addArrayPush(module, native.name, 4, I32, allocator));
						case "__array_push_f64":
							functions.set(native.name, WasmLinearArrays.addArrayPush(module, native.name, 8, F64, allocator));
						case "__array_pop_i32", "__array_pop_bool", "__array_pop_ref", "__array_pop_bytes":
							functions.set(native.name, WasmLinearArrays.addArrayPop(module, native.name, 4, I32));
						case "__array_pop_f64":
							functions.set(native.name, WasmLinearArrays.addArrayPop(module, native.name, 8, F64));
						case "__array_unshift_i32", "__array_unshift_bool", "__array_unshift_ref", "__array_unshift_bytes":
							functions.set(native.name, WasmLinearArrays.addArrayUnshift(module, native.name, 4, I32, allocator));
						case "__array_unshift_f64":
							functions.set(native.name, WasmLinearArrays.addArrayUnshift(module, native.name, 8, F64, allocator));
						case "__array_insert_i32", "__array_insert_bool", "__array_insert_ref", "__array_insert_bytes":
							functions.set(native.name, WasmLinearArrays.addArrayInsert(module, native.name, 4, I32, allocator));
						case "__array_insert_f64":
							functions.set(native.name, WasmLinearArrays.addArrayInsert(module, native.name, 8, F64, allocator));
						case "__array_shift_i32", "__array_shift_bool", "__array_shift_ref", "__array_shift_bytes":
							functions.set(native.name, WasmLinearArrays.addArrayShift(module, native.name, 4, I32));
						case "__array_shift_f64":
							functions.set(native.name, WasmLinearArrays.addArrayShift(module, native.name, 8, F64));
						case "__array_resize_i32", "__array_resize_bool", "__array_resize_ref", "__array_resize_bytes":
							functions.set(native.name, WasmLinearArrays.addArrayResize(module, native.name, 4, I32, allocator));
						case "__array_resize_f64":
							functions.set(native.name, WasmLinearArrays.addArrayResize(module, native.name, 8, F64, allocator));
						case "__array_remove_i32", "__array_remove_bool", "__array_remove_ref":
							functions.set(native.name, WasmLinearArrays.addArrayRemove(module, native.name, 4, I32, null));
						case "__array_remove_bytes":
							var stringEqual = functions.get("__string_equal");
							if (stringEqual == null) {
								stringEqual = addStringEqual(module, "__string_equal");
								functions.set("__string_equal", stringEqual);
							}
							functions.set(native.name, WasmLinearArrays.addArrayRemove(module, native.name, 4, I32, stringEqual));
						case "__array_remove_f64":
							functions.set(native.name, WasmLinearArrays.addArrayRemove(module, native.name, 8, F64, null));
						case "__array_reverse_i32", "__array_reverse_bool", "__array_reverse_ref", "__array_reverse_bytes":
							functions.set(native.name, WasmLinearArrays.addArrayReverse(module, native.name, 4, I32));
						case "__array_reverse_f64":
							functions.set(native.name, WasmLinearArrays.addArrayReverse(module, native.name, 8, F64));
						case "__array_splice_i32", "__array_splice_bool", "__array_splice_ref", "__array_splice_bytes":
							functions.set(native.name, WasmLinearArrays.addArraySplice(module, native.name, 4, allocator));
						case "__array_splice_f64":
							functions.set(native.name, WasmLinearArrays.addArraySplice(module, native.name, 8, allocator));
						default:
					}
			}
		}
		for (native in program.natives)
			if (native.name == "__dynamic_equal") {
				var stringEqual = functions.get("__string_equal");
				if (stringEqual == null) {
					stringEqual = addStringEqual(module, "__string_equal");
					functions.set("__string_equal", stringEqual);
				}
				functions.set(native.name, addDynamicEqual(module, native.name, stringEqual));
			}
	}

	/** Lower the stable haxeon_runtime symbol names used by generated HXI and stdlib code. */
	static function addRuntimeNativeFunction(module:WasmModule, native:compiler.ir.Ir.IrNative, allocator:Int):Null<Int> {
		return switch native.symbol {
			case "__math_is_finite", "__math_pow", "__math_cos", "__math_sin", "__math_tan", "__math_fmod", "__math_round", "__math_ceil",
				"__bytes_output_write", "__bytes_output_write_range", "__sys_print", "__sys_args", "__date_now", "__date_get_time":
				runtimeImportIndex(module, native);
			case "__math_is_nan": addMathIsNaN(module, native.name);
			case "sys_time", "sys_cpu_time", "sys_thread_cpu_time", "sys_process_memory", "sys_getpid", "sys_sleep", "sys_get_char", "sys_exit":
				runtimeImportIndex(module, native);
			case "__bytes_alloc": addBytesAlloc(module, native.name, allocator);
			case "__bytes_of_string": addBytesFromString(module, native.name, allocator);
			case "__bytes_view", "__bytes_sub", "structSlice": addBytesSlice(module, native.name, allocator);
			case "__bytes_length": addBytesLength(module, native.name);
			case "__bytes_compare": addBytesCompare(module, native.name);
			case "__bytes_get", "getU8": addBytesLoad(module, native.name, I32, I32Load8U(0));
			case "getI8": addBytesLoad(module, native.name, I32, I32Load8S(0));
			case "getU16": addBytesLoad(module, native.name, I32, I32Load16U(0));
			case "getI16": addBytesLoad(module, native.name, I32, I32Load16S(0));
			case "__bytes_get_i32", "getI32": addBytesLoad(module, native.name, I32, I32Load(0));
			case "getI64": addBytesLoad(module, native.name, I64, I64Load(0));
			case "getF32": addBytesLoad(module, native.name, F64, F32Load(0), [F64PromoteF32]);
			case "getF64": addBytesLoad(module, native.name, F64, F64Load(0));
			case "__bytes_set", "setI8", "setU8": addBytesStore(module, native.name, I32, I32Store8(0));
			case "__bytes_set_i32", "setI32": addBytesStore(module, native.name, I32, I32Store(0));
			case "setI16", "setU16": addBytesStore(module, native.name, I32, I32Store16(0));
			case "setI64": addBytesStore(module, native.name, I64, I64Store(0));
			case "setF32": addBytesStore(module, native.name, F64, F32Store(0), [F32DemoteF64]);
			case "setF64": addBytesStore(module, native.name, F64, F64Store(0));
			case "__bytes_get_data": addBytesData(module, native.name);
			case "__bytes_to_string": addBytesIdentity(module, native.name);
			case "__bytes_get_string": addBytesSlice(module, native.name, allocator);
			case "__string_from_bytes": addBytesPrefix(module, native.name, allocator);
			case "structCopy": addStructCopy(module, native.name);
			case "structCopyPointer": addStructCopyPointer(module, native.name, allocator);
			case "structSetBorrowedBytes": addStructSetBorrowedBytes(module, native.name);
			case "structGetPointer": addStructGetPointer(module, native.name);
			case "structSetPointer": addStructSetPointer(module, native.name);
			case "structGetUtf8": addStructGetUtf8(module, native.name, allocator);
			case "structSetUtf8": addStructSetUtf8(module, native.name);
			default: null;
		};
	}

	static function addBytesAlloc(module:WasmModule, name:String, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: [I32]}, [{type: I32}], [
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			Call(allocator),
			LocalSet(1),
			LocalGet(1),
			I32Const(WasmBackend.typeId(Bytes)),
			I32Store(0),
			LocalGet(1),
			LocalGet(0),
			I32Store(WasmLayout.STRING_LENGTH_OFFSET),
			LocalGet(1),
			LocalGet(0),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(1),
			Return
		]));
	}

	static function addBytesFromString(module:WasmModule, name:String, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: [I32]}, [{type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.STRING_LENGTH_OFFSET),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			Call(allocator),
			LocalSet(1),
			LocalGet(1),
			I32Const(WasmBackend.typeId(Bytes)),
			I32Store(0),
			LocalGet(1),
			LocalGet(0),
			I32Load(WasmLayout.STRING_LENGTH_OFFSET),
			I32Store(WasmLayout.STRING_LENGTH_OFFSET),
			LocalGet(1),
			LocalGet(0),
			I32Load(WasmLayout.STRING_LENGTH_OFFSET),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(1),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(0),
			I32Load(WasmLayout.STRING_LENGTH_OFFSET),
			MemoryCopy,
			LocalGet(1),
			Return
		]));
	}

	static function addBytesLength(module:WasmModule, name:String):Int
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: [I32]}, [],
			[LocalGet(0), I32Load(WasmLayout.STRING_LENGTH_OFFSET), Return]));

	static function addBytesCompare(module:WasmModule, name:String):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32], results: [I32]},
			[{type: I32}, {type: I32}, {type: I32}, {type: I32}, {type: I32}, {type: I32}], [
				LocalGet(0),
				I32Load(WasmLayout.STRING_LENGTH_OFFSET),
				LocalSet(2),
				LocalGet(1),
				I32Load(WasmLayout.STRING_LENGTH_OFFSET),
				LocalSet(3),
				I32Const(0),
				LocalSet(4),
				I32Const(0),
				LocalSet(5),
				Block(null),
				Loop(null),
				LocalGet(4),
				LocalGet(2),
				I32LtS,
				I32Eqz,
				LocalGet(4),
				LocalGet(3),
				I32LtS,
				I32Eqz,
				I32Or,
				BrIf(1),
				LocalGet(0),
				I32Const(WasmLayout.STRING_DATA_OFFSET),
				I32Add,
				LocalGet(4),
				I32Add,
				I32Load8U(0),
				LocalSet(6),
				LocalGet(1),
				I32Const(WasmLayout.STRING_DATA_OFFSET),
				I32Add,
				LocalGet(4),
				I32Add,
				I32Load8U(0),
				LocalSet(7),
				LocalGet(6),
				LocalGet(7),
				I32Eq,
				I32Eqz,
				If(null),
				LocalGet(6),
				LocalGet(7),
				I32LtS,
				If(null),
				I32Const(-1),
				LocalSet(5),
				Else,
				I32Const(1),
				LocalSet(5),
				End,
				Br(2),
				End,
				LocalGet(4),
				I32Const(1),
				I32Add,
				LocalSet(4),
				Br(0),
				End,
				End,
				LocalGet(5),
				I32Eqz,
				If(null),
				LocalGet(2),
				LocalGet(3),
				I32LtS,
				If(null),
				I32Const(-1),
				LocalSet(5),
				Else,
				LocalGet(3),
				LocalGet(2),
				I32LtS,
				If(null),
				I32Const(1),
				LocalSet(5),
				End,
				End,
				End,
				LocalGet(5),
				Return
			]));
	}

	static function addBytesData(module:WasmModule, name:String):Int
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: [I32]}, [],
			[LocalGet(0), I32Const(WasmLayout.STRING_DATA_OFFSET), I32Add, Return]));

	static function addBytesIdentity(module:WasmModule, name:String):Int
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: [I32]}, [], [LocalGet(0), Return]));

	static function addBytesLoad(module:WasmModule, name:String, result:WasmValueType, instruction:WasmInstruction, ?after:Array<WasmInstruction>):Int {
		var body:Array<WasmInstruction> = [
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(1),
			I32Add,
			instruction
		];
		if (after != null)
			for (item in after)
				body.push(item);
		body.push(Return);
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32], results: [result]}, [], body));
	}

	static function addBytesStore(module:WasmModule, name:String, valueType:WasmValueType, instruction:WasmInstruction, ?before:Array<WasmInstruction>):Int {
		var body:Array<WasmInstruction> = [
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(1),
			I32Add
		];
		body.push(LocalGet(2));
		if (before != null)
			for (item in before)
				body.push(item);
		body.push(instruction);
		body.push(Return);
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32, valueType], results: []}, [], body));
	}

	static function addBytesSlice(module:WasmModule, name:String, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32, I32], results: [I32]}, [{type: I32}], [
			LocalGet(2),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			Call(allocator),
			LocalSet(3),
			LocalGet(3),
			I32Const(WasmBackend.typeId(Bytes)),
			I32Store(0),
			LocalGet(3),
			LocalGet(2),
			I32Store(WasmLayout.STRING_LENGTH_OFFSET),
			LocalGet(3),
			LocalGet(2),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(3),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(1),
			I32Add,
			LocalGet(2),
			MemoryCopy,
			LocalGet(3),
			Return
		]));
	}

	static function addBytesPrefix(module:WasmModule, name:String, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32], results: [I32]}, [{type: I32}], [
			LocalGet(1),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			Call(allocator),
			LocalSet(2),
			LocalGet(2),
			I32Const(WasmBackend.typeId(Bytes)),
			I32Store(0),
			LocalGet(2),
			LocalGet(1),
			I32Store(WasmLayout.STRING_LENGTH_OFFSET),
			LocalGet(2),
			LocalGet(1),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(2),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(1),
			MemoryCopy,
			LocalGet(2),
			Return
		]));
	}

	static function addStructCopy(module:WasmModule, name:String):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32, I32, I32], results: []}, [], [
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(1),
			I32Add,
			LocalGet(2),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(3),
			MemoryCopy,
			Return
		]));
	}

	static function addStructSetBorrowedBytes(module:WasmModule, name:String):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32, I32], results: []}, [], [
			LocalGet(0), I32Const(WasmLayout.STRING_DATA_OFFSET), I32Add, LocalGet(1), I32Add,
			LocalGet(2), I32Const(WasmLayout.STRING_DATA_OFFSET), I32Add, I32Store(0), Return
		]));
	}

	static function addStructGetPointer(module:WasmModule, name:String):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32, I32], results: [I32]}, [], [
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(1),
			I32Add,
			I32Load(0),
			Return
		]));
	}

	static function addStructSetPointer(module:WasmModule, name:String):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32, I32, I32], results: []}, [], [
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(1),
			I32Add,
			LocalGet(2),
			I32Store(0),
			Return
		]));
	}

	static function addStructSetUtf8(module:WasmModule, name:String):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32, I32, I32], results: []}, [], [
			LocalGet(0), I32Const(WasmLayout.STRING_DATA_OFFSET), I32Add, LocalGet(1), I32Add,
			LocalGet(2), I32Const(WasmLayout.STRING_DATA_OFFSET), I32Add, I32Store(0), Return
		]));
	}

	static function addStructGetUtf8(module:WasmModule, name:String, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32, I32], results: [I32]}, [{type: I32}, {type: I32}, {type: I32}], [
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(1),
			I32Add,
			I32Load(0),
			LocalSet(3),
			LocalGet(3),
			I32Eqz,
			If(null),
			I32Const(0),
			LocalSet(2),
			Else,
			I32Const(0),
			LocalSet(4),
			Block(null),
			Loop(null),
			LocalGet(3),
			LocalGet(4),
			I32Add,
			I32Load8U(0),
			I32Eqz,
			If(null),
			Br(1),
			End,
			LocalGet(4),
			I32Const(1),
			I32Add,
			LocalSet(4),
			Br(0),
			End,
			End,
			LocalGet(4),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			Call(allocator),
			LocalSet(2),
			LocalGet(2),
			I32Const(WasmBackend.typeId(Bytes)),
			I32Store(0),
			LocalGet(2),
			LocalGet(4),
			I32Store(WasmLayout.STRING_LENGTH_OFFSET),
			LocalGet(2),
			LocalGet(4),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(2),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(3),
			LocalGet(4),
			MemoryCopy,
			End,
			LocalGet(2),
			Return
		]));
	}

	static function addStructCopyPointer(module:WasmModule, name:String, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32, I32, I32], results: [I32]}, [{type: I32}, {type: I32}, {type: I32}], [
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(1),
			I32Add,
			I32Load(0),
			LocalSet(4),
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(2),
			I32Add,
			I32Load(0),
			LocalSet(5),
			LocalGet(5),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			Call(allocator),
			LocalSet(6),
			LocalGet(6),
			I32Const(WasmBackend.typeId(Bytes)),
			I32Store(0),
			LocalGet(6),
			LocalGet(5),
			I32Store(WasmLayout.STRING_LENGTH_OFFSET),
			LocalGet(6),
			LocalGet(5),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(6),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(4),
			LocalGet(5),
			MemoryCopy,
			LocalGet(6),
			Return
		]));
	}

	public static function mapKeyType(mapName:String):IrType
		return StringTools.startsWith(mapName, "map_string_") ? Bytes : I32;

	public static function mapValueType(mapName:String):IrType
		return if (StringTools.endsWith(mapName,
			"_i32")) I32; else if (StringTools.endsWith(mapName,
			"_bool")) Bool; else if (StringTools.endsWith(mapName,
			"_f64")) F64; else if (StringTools.endsWith(mapName,
			"_bytes")) Bytes; else if (StringTools.endsWith(mapName, "_ref")) Dyn; else throw 'Unknown Wasm map value ABI "$mapName"';

	public static function mapEntrySize(valueType:IrType):Int
		return valueType == F64 ? 16 : 8;

	public static function mapValueOffset(valueType:IrType):Int
		return valueType == F64 ? 8 : 4;

	static function ensureStringEqual(module:WasmModule, functions:Map<String, Int>):Int {
		var result = functions.get("__string_equal");
		if (result == null) {
			result = addStringEqual(module, "__string_equal");
			functions.set("__string_equal", result);
		}
		return result;
	}

	static function ensureMapFind(module:WasmModule, functions:Map<String, Int>, mapName:String, keyType:IrType, valueType:IrType, stringEqual:Int):Int {
		var name = "__haxeon_map_find_" + mapName,
			result = functions.get(name);
		if (result == null) {
			result = addMapFind(module, name, keyType, valueType, stringEqual);
			functions.set(name, result);
		}
		return result;
	}

	static function ensureMapArrayAllocator(module:WasmModule, functions:Map<String, Int>, allocator:Int, valueType:IrType):Int {
		var suffix = valueType == F64 ? "f64" : "i32",
			name = "__array_alloc_" + suffix,
			result = functions.get(name);
		if (result == null) {
			result = WasmLinearArrays.addArrayAllocator(module, name, valueType == F64 ? 8 : 4, allocator);
			functions.set(name, result);
		}
		return result;
	}

	static function addMapRuntimeFunction(module:WasmModule, functions:Map<String, Int>, name:String, mapName:String, operation:String, allocator:Int):Int {
		var keyType = mapKeyType(mapName),
			valueType = mapValueType(mapName),
			stringEqual = keyType == Bytes ? ensureStringEqual(module, functions) : 0;
		var entrySize = mapEntrySize(valueType),
			valueOffset = mapValueOffset(valueType);
		return switch operation {
			case "alloc": addMapAlloc(module, name, mapName, entrySize, allocator);
			case "set": addMapSet(module, name, keyType, valueType, entrySize, valueOffset, allocator, stringEqual);
			case "exists": addMapExists(module, name, keyType, valueType, stringEqual,
					ensureMapFind(module, functions, mapName, keyType, valueType, stringEqual));
			case "get": addMapGet(module, name, keyType, valueType, entrySize, valueOffset, allocator, stringEqual,
					ensureMapFind(module, functions, mapName, keyType, valueType, stringEqual));
			case "keys": addMapProjection(module, name, keyType, entrySize, 0, allocator, ensureMapArrayAllocator(module, functions, allocator, keyType));
			case "values": addMapProjection(module, name, valueType, entrySize, valueOffset, allocator,
					ensureMapArrayAllocator(module, functions, allocator, valueType));
			case "remove": addMapRemove(module, name, keyType, valueType, entrySize, stringEqual,
					ensureMapFind(module, functions, mapName, keyType, valueType, stringEqual));
			case "clear": addMapClear(module, name);
			case "size": addMapSize(module, name);
			default: throw 'Unknown Wasm map operation "$operation"';
		};
	}

	static function addMapAlloc(module:WasmModule, name:String, mapName:String, entrySize:Int, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [], results: [I32]}, [{type: I32}, {type: I32}], [
			I32Const(WasmLayout.MAP_HEADER_SIZE),
			Call(allocator),
			LocalTee(0),
			I32Const(WasmBackend.typeId(Abstract(mapName))),
			I32Store(0),
			LocalGet(0),
			I32Const(0),
			I32Store(WasmLayout.MAP_COUNT_OFFSET),
			LocalGet(0),
			I32Const(8),
			I32Store(WasmLayout.MAP_CAPACITY_OFFSET),
			I32Const(entrySize * 8),
			Call(allocator),
			LocalSet(1),
			LocalGet(1),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Sub,
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			LocalGet(0),
			I32Store(0),
			LocalGet(0),
			LocalGet(1),
			I32Store(WasmLayout.MAP_ENTRIES_OFFSET),
			LocalGet(0),
			Return
		]));
	}

	static function mapEntryAddress(entriesLocal:Int, indexLocal:Int, entrySize:Int):Array<WasmInstruction>
		return [
			LocalGet(entriesLocal),
			LocalGet(indexLocal),
			I32Const(entrySize),
			I32Mul,
			I32Add
		];

	public static function append(body:Array<WasmInstruction>, instructions:Array<WasmInstruction>):Void
		for (instruction in instructions)
			body.push(instruction);

	static function mapKeyCompare(keyType:IrType, stringEqual:Int):Array<WasmInstruction>
		return keyType == Bytes ? [LocalGet(1), Call(stringEqual),] : [LocalGet(1), I32Eq];

	static function loadMapValue(type:IrType, offset:Int):WasmInstruction
		return type == F64 ? F64Load(offset) : I32Load(offset);

	static function storeMapValue(type:IrType, offset:Int):WasmInstruction
		return type == F64 ? F64Store(offset) : I32Store(offset);

	static function addMapFind(module:WasmModule, name:String, keyType:IrType, valueType:IrType, stringEqual:Int):Int {
		var entrySize = mapEntrySize(valueType),
			body:Array<WasmInstruction> = [
				I32Const(0),
				LocalSet(2),
				Block(null),
				Loop(null),
				LocalGet(2),
				LocalGet(0),
				I32Load(WasmLayout.MAP_COUNT_OFFSET),
				I32LtS,
				If(null)
			];
		append(body, [LocalGet(0), I32Load(WasmLayout.MAP_ENTRIES_OFFSET), LocalSet(3)]);
		for (instruction in mapEntryAddress(3, 2, entrySize))
			body.push(instruction);
		body.push(I32Load(0));
		for (instruction in mapKeyCompare(keyType, stringEqual))
			body.push(instruction);
		append(body, [
			If(null),
			LocalGet(2),
			Return,
			End,
			LocalGet(2),
			I32Const(1),
			I32Add,
			LocalSet(2),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End,
			I32Const(-1),
			Return
		]);
		return module.addFunction(new WasmFunction(name, {parameters: [I32, WasmBackend.requireValueType(keyType)], results: [I32]},
			[{type: I32}, {type: I32}], body));
	}

	static function addMapSet(module:WasmModule, name:String, keyType:IrType, valueType:IrType, entrySize:Int, valueOffset:Int, allocator:Int,
			stringEqual:Int):Int {
		var body:Array<WasmInstruction> = [
			                         I32Const(0), LocalSet(3), Block(null),  Loop(null),                            LocalGet(3), LocalGet(0),
			I32Load(WasmLayout.MAP_COUNT_OFFSET),      I32LtS,    If(null), LocalGet(0), I32Load(WasmLayout.MAP_ENTRIES_OFFSET), LocalSet(4)
		];
		for (instruction in mapEntryAddress(4, 3, entrySize))
			body.push(instruction);
		body.push(I32Load(0));
		for (instruction in mapKeyCompare(keyType, stringEqual))
			body.push(instruction);
		body.push(If(null));
		for (instruction in mapEntryAddress(4, 3, entrySize))
			body.push(instruction);
		append(body, [LocalGet(1), I32Store(0)]);
		for (instruction in mapEntryAddress(4, 3, entrySize))
			body.push(instruction);
		append(body, [
			LocalGet(2),
			storeMapValue(valueType, valueOffset),
			Return,
			End,
			LocalGet(3),
			I32Const(1),
			I32Add,
			LocalSet(3),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End,
			LocalGet(0),
			I32Load(WasmLayout.MAP_COUNT_OFFSET),
			LocalSet(5),
			LocalGet(0),
			I32Load(WasmLayout.MAP_CAPACITY_OFFSET),
			LocalSet(6),
			LocalGet(5),
			LocalGet(6),
			I32Eq,
			If(null),
			LocalGet(6),
			I32Const(2),
			I32Mul,
			LocalSet(7),
			LocalGet(7),
			I32Const(entrySize),
			I32Mul,
			Call(allocator),
			LocalSet(8),
			LocalGet(8),
			LocalGet(0),
			I32Load(WasmLayout.MAP_ENTRIES_OFFSET),
			LocalGet(5),
			I32Const(entrySize),
			I32Mul,
			MemoryCopy,
			LocalGet(8),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Sub,
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			LocalGet(0),
			I32Store(0),
			LocalGet(0),
			LocalGet(8),
			I32Store(WasmLayout.MAP_ENTRIES_OFFSET),
			LocalGet(0),
			LocalGet(7),
			I32Store(WasmLayout.MAP_CAPACITY_OFFSET),
			End,
			LocalGet(0),
			I32Load(WasmLayout.MAP_ENTRIES_OFFSET),
			LocalSet(4)
		]);
		for (instruction in mapEntryAddress(4, 5, entrySize))
			body.push(instruction);
		append(body, [LocalGet(1), I32Store(0)]);
		for (instruction in mapEntryAddress(4, 5, entrySize))
			body.push(instruction);
		append(body, [
			LocalGet(2),
			storeMapValue(valueType, valueOffset),
			LocalGet(0),
			LocalGet(5),
			I32Const(1),
			I32Add,
			I32Store(WasmLayout.MAP_COUNT_OFFSET),
		]);
		return module.addFunction(new WasmFunction(name, {
			parameters: [
				I32,
				WasmBackend.requireValueType(keyType),
				WasmBackend.requireValueType(valueType)
			],
			results: []
		},
			[{type: I32}, {type: I32}, {type: I32}, {type: I32}, {type: I32}, {type: I32}], body));
	}

	static function addMapExists(module:WasmModule, name:String, keyType:IrType, valueType:IrType, stringEqual:Int, find:Int):Int
		return module.addFunction(new WasmFunction(name, {parameters: [I32, WasmBackend.requireValueType(keyType)], results: [I32]}, [],
			[LocalGet(0), LocalGet(1), Call(find), I32Const(-1), I32Eq, I32Eqz, Return]));

	static function addMapGet(module:WasmModule, name:String, keyType:IrType, valueType:IrType, entrySize:Int, valueOffset:Int, allocator:Int,
			stringEqual:Int, find:Int):Int {
		var body:Array<WasmInstruction> = [
			LocalGet(0),
			LocalGet(1),
			Call(find),
			LocalSet(2),
			LocalGet(2),
			I32Const(-1),
			I32Eq,
			If(null),
			I32Const(0),
			LocalSet(4),
			Else,
			LocalGet(0),
			I32Load(WasmLayout.MAP_ENTRIES_OFFSET),
			LocalSet(3)
		];
		if (valueType == I32 || valueType == Bool) {
			append(body, [
				I32Const(WasmLayout.DYN_I32_SIZE),
				Call(allocator),
				LocalSet(4),
				LocalGet(4),
				I32Const(WasmBackend.typeId(valueType)),
				I32Store(0)
			]);
			append(body, [LocalGet(4)]);
			for (instruction in mapEntryAddress(3, 2, entrySize))
				body.push(instruction);
			append(body, [I32Load(valueOffset), I32Store(WasmLayout.DYN_PAYLOAD_OFFSET)]);
		} else if (valueType == F64) {
			append(body, [
				I32Const(WasmLayout.DYN_F64_SIZE),
				Call(allocator),
				LocalSet(4),
				LocalGet(4),
				I32Const(WasmBackend.typeId(F64)),
				I32Store(0)
			]);
			append(body, [LocalGet(4)]);
			for (instruction in mapEntryAddress(3, 2, entrySize))
				body.push(instruction);
			append(body, [F64Load(valueOffset), F64Store(WasmLayout.DYN_PAYLOAD_OFFSET)]);
		} else {
			for (instruction in mapEntryAddress(3, 2, entrySize))
				body.push(instruction);
			append(body, [loadMapValue(valueType, valueOffset), LocalSet(4)]);
		}
		append(body, [End, LocalGet(4), Return]);
		return module.addFunction(new WasmFunction(name, {parameters: [I32, WasmBackend.requireValueType(keyType)], results: [I32]},
			[{type: I32}, {type: I32}, {type: I32}], body));
	}

	static function addMapProjection(module:WasmModule, name:String, elementType:IrType, entrySize:Int, valueOffset:Int, allocator:Int,
			arrayAllocator:Int):Int {
		var stride = WasmLayout.arrayStride(elementType),
			body:Array<WasmInstruction> = [
				LocalGet(0),
				I32Load(WasmLayout.MAP_COUNT_OFFSET),
				Call(arrayAllocator),
				LocalSet(1),
				LocalGet(0),
				I32Load(WasmLayout.MAP_ENTRIES_OFFSET),
				LocalSet(2),
				I32Const(0),
				LocalSet(3),
				Block(null),
				Loop(null),
				LocalGet(3),
				LocalGet(0),
				I32Load(WasmLayout.MAP_COUNT_OFFSET),
				I32LtS,
				If(null),
				LocalGet(1),
				I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
				LocalGet(3),
				I32Const(stride),
				I32Mul,
				I32Add
			];
		for (instruction in mapEntryAddress(2, 3, entrySize))
			body.push(instruction);
		append(body, [
			loadMapValue(elementType, valueOffset),
			storeMapValue(elementType, 0),
			LocalGet(3),
			I32Const(1),
			I32Add,
			LocalSet(3),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End,
			LocalGet(1),
			Return
		]);
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: [I32]}, [{type: I32}, {type: I32}, {type: I32}], body));
	}

	static function addMapRemove(module:WasmModule, name:String, keyType:IrType, valueType:IrType, entrySize:Int, stringEqual:Int, find:Int):Int {
		var body:Array<WasmInstruction> = [
			LocalGet(0),
			LocalGet(1),
			Call(find),
			LocalTee(2),
			I32Const(-1),
			I32Eq,
			If(I32),
			I32Const(0),
			Else,
			LocalGet(0),
			I32Load(WasmLayout.MAP_ENTRIES_OFFSET),
			LocalSet(3),
			LocalGet(0),
			I32Load(WasmLayout.MAP_COUNT_OFFSET),
			LocalSet(4),
			LocalGet(4),
			LocalGet(2),
			I32Sub,
			I32Const(1),
			I32Sub,
			LocalSet(5),
			I32Const(0),
			LocalGet(5),
			I32LtS,
			If(null)
		];
		var destination = mapEntryAddress(3, 2, entrySize),
			source:Array<WasmInstruction> = [
				LocalGet(3),
				LocalGet(2),
				I32Const(1),
				I32Add,
				I32Const(entrySize),
				I32Mul,
				I32Add
			];
		for (instruction in destination)
			body.push(instruction);
		for (instruction in source)
			body.push(instruction);
		append(body, [
			LocalGet(5),
			I32Const(entrySize),
			I32Mul,
			MemoryCopy,
			End,
			LocalGet(0),
			LocalGet(4),
			I32Const(1),
			I32Sub,
			I32Store(WasmLayout.MAP_COUNT_OFFSET),
			I32Const(1),
			End,
			Return
		]);
		return module.addFunction(new WasmFunction(name, {parameters: [I32, WasmBackend.requireValueType(keyType)], results: [I32]},
			[{type: I32}, {type: I32}, {type: I32}, {type: I32}], body));
	}

	static function addMapClear(module:WasmModule, name:String):Int
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: []}, [],
			[LocalGet(0), I32Const(0), I32Store(WasmLayout.MAP_COUNT_OFFSET)]));

	static function addMapSize(module:WasmModule, name:String):Int
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: [I32]}, [], [LocalGet(0), I32Load(WasmLayout.MAP_COUNT_OFFSET), Return]));

	static function addDynamicInt(module:WasmModule, name:String):Int
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: [I32]}, [], [
			LocalGet(0),
			I32Eqz,
			If(null),
			I32Const(0),
			Return,
			End,
			LocalGet(0),
			I32Load(0),
			I32Const(WasmBackend.typeId(I32)),
			I32Eq,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			Return,
			End,
			LocalGet(0),
			I32Load(0),
			I32Const(WasmBackend.typeId(Bool)),
			I32Eq,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			Return,
			End,
			LocalGet(0),
			I32Load(0),
			I32Const(WasmBackend.typeId(F64)),
			I32Eq,
			If(null),
			LocalGet(0),
			F64Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			I32TruncF64S,
			Return,
			End,
			LocalGet(0),
			I32Load(0),
			I32Const(WasmBackend.typeId(I64)),
			I32Eq,
			If(null),
			LocalGet(0),
			I64Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			I32WrapI64,
			Return,
			End,
			Unreachable
		]));

	static function addDynamicIsObject(module:WasmModule, name:String, program:IrProgram):Int {
		var body:Array<WasmInstruction> = [];
		for (object in program.objects) {
			body.push(LocalGet(0));
			body.push(I32Const(WasmBackend.typeId(Obj(object.name))));
			body.push(I32Eq);
			body.push(If(null));
			body.push(I32Const(1));
			body.push(Return);
			body.push(End);
		}
		for (enumDecl in program.enums) {
			body.push(LocalGet(0));
			body.push(I32Const(WasmBackend.typeId(Enum(enumDecl.name))));
			body.push(I32Eq);
			body.push(If(null));
			body.push(I32Const(1));
			body.push(Return);
			body.push(End);
		}
		body = body.concat([
			LocalGet(0),
			I32Const(1),
			I32And,
			If(null),
			I32Const(0),
			Return,
			End,
			LocalGet(0),
			I32Eqz,
			If(null),
			I32Const(0),
			Return,
			End,
			LocalGet(0),
			I32Load(0),
			I32Const(WasmLayout.CLOSURE_TYPE_ID),
			I32Eq,
			If(null),
			I32Const(0),
			Return,
			End,
			LocalGet(0),
			I32Load(0),
			I32Const(WasmBackend.typeId(I32)),
			I32Eq,
			If(null),
			I32Const(0),
			Return,
			End,
			LocalGet(0),
			I32Load(0),
			I32Const(WasmBackend.typeId(Bool)),
			I32Eq,
			If(null),
			I32Const(0),
			Return,
			End,
			LocalGet(0),
			I32Load(0),
			I32Const(WasmBackend.typeId(I64)),
			I32Eq,
			If(null),
			I32Const(0),
			Return,
			End,
			LocalGet(0),
			I32Load(0),
			I32Const(WasmBackend.typeId(F64)),
			I32Eq,
			If(null),
			I32Const(0),
			Return,
			End,
			LocalGet(0),
			I32Load(0),
			I32Const(WasmBackend.typeId(Bytes)),
			I32Eq,
			If(null),
			I32Const(0),
			Return,
			End,
			I32Const(1),
			Return
		]);
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: [I32]}, [], body));
	}

	static function addTypeTest(module:WasmModule, name:String, program:IrProgram):Int {
		var body:Array<WasmInstruction> = [
			LocalGet(0),
			I32Eqz,
			If(null),
			I32Const(0),
			LocalSet(2),
			Else,
			LocalGet(0),
			I32Load(0),
			LocalGet(1),
			I32Eq,
			LocalSet(2),
		];
		for (object in program.objects) {
			var accepted = [WasmBackend.typeId(Obj(object.name))];
			var base = object.base;
			while (base != null) {
				accepted.push(WasmBackend.typeId(Obj(base)));
				var next:Null<String> = null;
				for (candidate in program.objects)
					if (candidate.name == base)
						next = candidate.base;
				base = next;
			}
			for (interfaceName in object.interfaces)
				accepted.push(WasmBackend.typeId(Virtual(interfaceName)));
			body.push(LocalGet(0));
			body.push(I32Load(0));
			body.push(I32Const(WasmBackend.typeId(Obj(object.name))));
			body.push(I32Eq);
			body.push(If(null));
			for (index in 0...accepted.length) {
				body.push(LocalGet(1));
				body.push(I32Const(accepted[index]));
				body.push(I32Eq);
				if (index > 0)
					body.push(I32Or);
			}
			body.push(LocalSet(2));
			body.push(End);
		}
		body.push(End);
		body.push(LocalGet(2));
		body.push(Return);
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32], results: [I32]}, [{type: I32}], body));
	}

	static function addStringCharCodeAt(module:WasmModule, name:String):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32], results: [I32]}, [{type: I32}], [
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(1),
			I32Add,
			I32Load8U(0),
			Return
		]));
	}

	static function addStringConcat(module:WasmModule, name:String, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32], results: [I32]}, [{type: I32}, {type: I32}, {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.STRING_LENGTH_OFFSET),
			LocalSet(2),
			LocalGet(1),
			I32Load(WasmLayout.STRING_LENGTH_OFFSET),
			LocalSet(3),
			LocalGet(2),
			LocalGet(3),
			I32Add,
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			Call(allocator),
			LocalSet(4),
			LocalGet(4),
			I32Const(WasmBackend.typeId(Bytes)),
			I32Store(0),
			LocalGet(4),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(2),
			MemoryCopy,
			LocalGet(4),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(2),
			I32Add,
			LocalGet(1),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(3),
			MemoryCopy,
			LocalGet(4),
			LocalGet(2),
			LocalGet(3),
			I32Add,
			I32Store(WasmLayout.STRING_LENGTH_OFFSET),
			LocalGet(4),
			LocalGet(2),
			LocalGet(3),
			I32Add,
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(4),
			Return
		]));
	}

	static function addIntToString(module:WasmModule, name:String, allocator:Int):Int {
		var type:WasmFunctionType = {parameters: [I32], results: [I32]},
			body:Array<WasmInstruction> = [
				LocalGet(0),
				LocalSet(1),
				I32Const(0),
				LocalSet(2),
				LocalGet(0),
				I32Const(0),
				I32LtS,
				LocalSet(3),
				Block(null),
				Loop(null),
				LocalGet(2),
				I32Const(1),
				I32Add,
				LocalSet(2),
				LocalGet(1),
				I32Const(10),
				I32DivS,
				LocalTee(1),
				I32Eqz,
				BrIf(1),
				Br(0),
				End,
				End,
				LocalGet(2),
				LocalGet(3),
				I32Add,
				I32Const(WasmLayout.STRING_DATA_OFFSET),
				I32Add,
				Call(allocator),
				LocalSet(4),
				LocalGet(4),
				I32Const(WasmBackend.typeId(Bytes)),
				I32Store(0),
				LocalGet(4),
				LocalGet(2),
				LocalGet(3),
				I32Add,
				I32Store(WasmLayout.STRING_LENGTH_OFFSET),
				LocalGet(4),
				LocalGet(2),
				LocalGet(3),
				I32Add,
				I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
				LocalGet(0),
				LocalSet(1),
				LocalGet(2),
				LocalGet(3),
				I32Add,
				I32Const(1),
				I32Sub,
				LocalSet(5),
				Block(null),
				Loop(null),
				LocalGet(2),
				I32Eqz,
				BrIf(1),
				LocalGet(1),
				I32Const(10),
				I32RemS,
				LocalSet(6),
				LocalGet(1),
				I32Const(10),
				I32DivS,
				LocalSet(1),
				LocalGet(4),
				I32Const(WasmLayout.STRING_DATA_OFFSET),
				I32Add,
				LocalGet(5),
				I32Add,
				LocalGet(3),
				If(null),
				I32Const(48),
				LocalGet(6),
				I32Sub,
				LocalSet(7),
				Else,
				I32Const(48),
				LocalGet(6),
				I32Add,
				LocalSet(7),
				End,
				LocalGet(7),
				I32Store8(0),
				LocalGet(2),
				I32Const(1),
				I32Sub,
				LocalSet(2),
				LocalGet(5),
				I32Const(1),
				I32Sub,
				LocalSet(5),
				Br(0),
				End,
				End,
				LocalGet(3),
				If(null),
				LocalGet(4),
				I32Const(WasmLayout.STRING_DATA_OFFSET),
				I32Add,
				I32Const(45),
				I32Store8(0),
				End,
				LocalGet(4),
				Return
			];
		return module.addFunction(new WasmFunction(name, type, [for (_ in 0...7) {type: I32}], body));
	}

	static function addInt64ToString(module:WasmModule, name:String, allocator:Int):Int {
		var body:Array<WasmInstruction> = [
			LocalGet(0),
			I64Const(0),
			I64LtS,
			LocalSet(1),
			LocalGet(1),
			If(I64),
			LocalGet(0),
			Else,
			I64Const(0),
			LocalGet(0),
			I64Sub,
			End,
			LocalSet(3),
			I32Const(1),
			LocalSet(2),
			Block(null),
			Loop(null),
			LocalGet(3),
			I64Const(-10),
			I64LeS,
			I32Eqz,
			BrIf(1),
			LocalGet(3),
			I64Const(10),
			I64DivS,
			LocalSet(3),
			LocalGet(2),
			I32Const(1),
			I32Add,
			LocalSet(2),
			Br(0),
			End,
			End,
			LocalGet(1),
			If(I64),
			LocalGet(0),
			Else,
			I64Const(0),
			LocalGet(0),
			I64Sub,
			End,
			LocalSet(3),
			LocalGet(2),
			LocalGet(1),
			I32Add,
			LocalTee(5),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			Call(allocator),
			LocalSet(4),
			LocalGet(4),
			I32Const(WasmBackend.typeId(Bytes)),
			I32Store(0),
			LocalGet(4),
			LocalGet(5),
			I32Store(WasmLayout.STRING_LENGTH_OFFSET),
			LocalGet(4),
			LocalGet(5),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(2),
			I32Const(1),
			I32Sub,
			LocalGet(1),
			I32Add,
			LocalSet(6),
			Block(null),
			Loop(null),
			I32Const(0),
			LocalGet(3),
			I64Const(10),
			I64RemS,
			I32WrapI64,
			I32Sub,
			I32Const(48),
			I32Add,
			LocalSet(7),
			LocalGet(4),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(6),
			I32Add,
			LocalGet(7),
			I32Store8(0),
			LocalGet(3),
			I64Const(10),
			I64DivS,
			LocalSet(3),
			LocalGet(3),
			I64Eqz,
			BrIf(1),
			LocalGet(6),
			I32Const(1),
			I32Sub,
			LocalSet(6),
			Br(0),
			End,
			End,
			LocalGet(1),
			If(null),
			LocalGet(4),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			I32Const(45),
			I32Store8(0),
			End,
			LocalGet(4),
			Return
		];
		return module.addFunction(new WasmFunction(name, {parameters: [I64], results: [I32]}, [
			{type: I32},
			{type: I32},
			{type: I64},
			{type: I32},
			{type: I32},
			{type: I32},
			{type: I32}
		], body));
	}

	static function addDynamicString(module:WasmModule, name:String, allocator:Int, strings:Map<String, Int>, ryuTableBase:Int):Int {
		var integerString = addIntToString(module, "__haxeon_i32_to_string", allocator),
			int64String = addInt64ToString(module, "__haxeon_i64_to_string", allocator),
			floatString = WasmNumericString.addFloatToString(module, "__haxeon_f64_to_string", allocator, WasmBackend.typeId(Bytes), ryuTableBase,
				requiredStringOffset(strings, "NaN"), requiredStringOffset(strings, "Infinity"), requiredStringOffset(strings, "-Infinity"),
				requiredStringOffset(strings, "0")),
			nullString = requiredStringOffset(strings, "null"),
			trueString = requiredStringOffset(strings, "true"),
			falseString = requiredStringOffset(strings, "false"),
			body:Array<WasmInstruction> = [
				LocalGet(0),
				I32Eqz,
				If(null),
				I32Const(nullString),
				Return,
				End,
				LocalGet(0),
				I32Load(0),
				I32Const(WasmBackend.typeId(I64)),
				I32Eq,
				If(null),
				LocalGet(0),
				I64Load(WasmLayout.DYN_PAYLOAD_OFFSET),
				Call(int64String),
				Return,
				End,
				LocalGet(0),
				I32Load(0),
				I32Const(WasmBackend.typeId(F64)),
				I32Eq,
				If(null),
				LocalGet(0),
				F64Load(WasmLayout.DYN_PAYLOAD_OFFSET),
				Call(floatString),
				Return,
				End,
				LocalGet(0),
				I32Load(0),
				I32Const(WasmBackend.typeId(Bytes)),
				I32Eq,
				If(null),
				LocalGet(0),
				Return,
				End,
				LocalGet(0),
				I32Load(0),
				I32Const(WasmBackend.typeId(I32)),
				I32Eq,
				If(null),
				LocalGet(0),
				I32Load(WasmLayout.DYN_PAYLOAD_OFFSET),
				Call(integerString),
				Return,
				End,
				LocalGet(0),
				I32Load(0),
				I32Const(WasmBackend.typeId(Bool)),
				I32Eq,
				If(null),
				LocalGet(0),
				I32Load(WasmLayout.DYN_PAYLOAD_OFFSET),
				If(I32),
				I32Const(trueString),
				Else,
				I32Const(falseString),
				End,
				Return,
				End,
				Unreachable
			];
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: [I32]}, [{type: I32}], body));
	}

	static function addStringEqual(module:WasmModule, name:String):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32], results: [I32]}, [{type: I32}, {type: I32}, {type: I32}, {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.STRING_LENGTH_OFFSET),
			LocalSet(2),
			LocalGet(1),
			I32Load(WasmLayout.STRING_LENGTH_OFFSET),
			LocalSet(3),
			I32Const(0),
			LocalSet(4),
			I32Const(0),
			LocalSet(5),
			LocalGet(2),
			LocalGet(3),
			I32Eq,
			If(null),
			I32Const(1),
			LocalSet(5),
			Block(null),
			Loop(null),
			LocalGet(4),
			LocalGet(2),
			I32LtS,
			If(null),
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(4),
			I32Add,
			I32Load8U(0),
			LocalGet(1),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(4),
			I32Add,
			I32Load8U(0),
			I32Eq,
			If(null),
			LocalGet(4),
			I32Const(1),
			I32Add,
			LocalSet(4),
			Br(2),
			Else,
			I32Const(0),
			LocalSet(5),
			Br(3),
			End,
			Else,
			Br(2),
			End,
			End,
			End,
			Else,
			I32Const(0),
			LocalSet(5),
			End,
			LocalGet(5),
			Return
		]));
	}

	static function addStringCompareFull(module:WasmModule, name:String):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32], results: [I32]}, [for (_ in 0...7) {type: I32}], [
			LocalGet(0),
			LocalGet(1),
			I32Eq,
			If(null),
			I32Const(0),
			Return,
			End,
			LocalGet(0),
			I32Eqz,
			If(null),
			I32Const(-1),
			Return,
			End,
			LocalGet(1),
			I32Eqz,
			If(null),
			I32Const(1),
			Return,
			End,
			LocalGet(0),
			I32Load(WasmLayout.STRING_LENGTH_OFFSET),
			LocalSet(2),
			LocalGet(1),
			I32Load(WasmLayout.STRING_LENGTH_OFFSET),
			LocalSet(3),
			LocalGet(2),
			LocalGet(3),
			I32LtS,
			If(I32),
			LocalGet(2),
			Else,
			LocalGet(3),
			End,
			LocalSet(4),
			I32Const(0),
			LocalSet(5),
			I32Const(0),
			LocalSet(8),
			Block(null),
			Loop(null),
			LocalGet(5),
			LocalGet(4),
			I32LtS,
			I32Eqz,
			BrIf(1),
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(5),
			I32Add,
			I32Load8U(0),
			LocalSet(6),
			LocalGet(1),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(5),
			I32Add,
			I32Load8U(0),
			LocalSet(7),
			LocalGet(6),
			LocalGet(7),
			I32Sub,
			LocalSet(8),
			LocalGet(8),
			I32Eqz,
			I32Eqz,
			If(null),
			Br(2),
			End,
			LocalGet(5),
			I32Const(1),
			I32Add,
			LocalSet(5),
			Br(0),
			End,
			End,
			LocalGet(8),
			I32Eqz,
			If(null),
			LocalGet(2),
			LocalGet(3),
			I32Sub,
			LocalSet(8),
			End,
			LocalGet(8),
			Return
		]));
	}

	static function addMathIsNaN(module:WasmModule, name:String):Int
		return module.addFunction(new WasmFunction(name, {parameters: [F64], results: [I32]}, [], [LocalGet(0), LocalGet(0), F64Eq, I32Eqz, Return]));

	static function addDynamicEqual(module:WasmModule, name:String, stringEqual:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32], results: [I32]}, [{type: I32}, {type: I32}, {type: I32}], [
			I32Const(0),
			LocalSet(2),
			LocalGet(0),
			LocalGet(1),
			I32Eq,
			If(null),
			LocalGet(0),
			I32Eqz,
			If(null),
			I32Const(1),
			LocalSet(2),
			Else,
			LocalGet(0),
			I32Load(0),
			I32Const(WasmBackend.typeId(F64)),
			I32Eq,
			If(null),
			LocalGet(0),
			F64Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			LocalGet(1),
			F64Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			F64Eq,
			LocalSet(2),
			Else,
			I32Const(1),
			LocalSet(2),
			End,
			End,
			Else,
			LocalGet(0),
			I32Eqz,
			If(null),
			Else,
			LocalGet(1),
			I32Eqz,
			If(null),
			Else,
			LocalGet(0),
			I32Load(0),
			LocalSet(3),
			LocalGet(1),
			I32Load(0),
			LocalSet(4),
			LocalGet(3),
			LocalGet(4),
			I32Eq,
			If(null),
			LocalGet(3),
			I32Const(WasmBackend.typeId(Bytes)),
			I32Eq,
			If(null),
			LocalGet(0),
			LocalGet(1),
			Call(stringEqual),
			LocalSet(2),
			Else,
			LocalGet(3),
			I32Const(WasmBackend.typeId(I32)),
			I32Eq,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			LocalGet(1),
			I32Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			I32Eq,
			LocalSet(2),
			Else,
			LocalGet(3),
			I32Const(WasmBackend.typeId(Bool)),
			I32Eq,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			LocalGet(1),
			I32Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			I32Eq,
			LocalSet(2),
			Else,
			LocalGet(3),
			I32Const(WasmBackend.typeId(F64)),
			I32Eq,
			If(null),
			LocalGet(0),
			F64Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			LocalGet(1),
			F64Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			F64Eq,
			LocalSet(2),
			Else,
			LocalGet(3),
			I32Const(WasmBackend.typeId(I64)),
			I32Eq,
			If(null),
			LocalGet(0),
			I64Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			LocalGet(1),
			I64Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			I64Eq,
			LocalSet(2),
			Else,
			End,
			End,
			End,
			End,
			End,
			Else,
			End,
			End,
			End,
			End,
			LocalGet(2),
			Return
		]));
	}

	static function requiredStringOffset(strings:Map<String, Int>, value:String):Int {
		var offset = strings.get(value);
		if (offset == null)
			throw 'Missing Wasm string data for "$value"';
		return offset;
	}

	static function resultTypes(type:IrType):Array<WasmValueType>
		return type == Void ? [] : [WasmBackend.requireValueType(type)];
}
