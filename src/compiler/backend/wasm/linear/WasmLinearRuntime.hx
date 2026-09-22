package compiler.backend.wasm.linear;

import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmFunctionBuilder.WasmFunctionBuilder;
import compiler.backend.wasm.WasmFunctionBuilder.WasmLocalRef;
import compiler.backend.wasm.WasmModuleSupport;

class WasmLinearRuntime {
	public static function addImports(context:WasmLinearContext, used:Map<String, Bool>):Void {
		var module = context.module, program = context.program;
		for (native in program.natives)
			if (used.exists(native.name))
				switch native.symbol {
					case "__math_is_finite", "__math_pow", "__math_cos", "__math_sin", "__math_tan", "__math_fmod", "__math_round", "__math_ceil",
						"__math_floor", "__sys_print", "__sys_args", "__date_now", "__date_get_time", "sys_time", "sys_cpu_time", "sys_thread_cpu_time",
						"sys_process_memory", "sys_getpid", "sys_sleep", "sys_get_char", "sys_exit", "native_callback_create", "native_callback_close",
						"native_callback_error_kind", "native_callback_take_error":
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
			{parameters: [for (argument in native.arguments) WasmModuleSupport.requireValueType(argument)], results: resultTypes(native.result)});
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
			bytesDataPointer = addBytesDataPointer(module);
		functions.set("__haxeon_bytes_data_pointer", bytesDataPointer);
		var outputReserve = addBytesOutputReserve(module, allocator, bytesDataPointer);
		functions.set("__haxeon_bytes_output_reserve", outputReserve);
		for (native in program.natives) {
			var runtimeFunction = addRuntimeNativeFunction(module, native, allocator, bytesDataPointer, outputReserve);
			if (runtimeFunction != null)
				functions.set(native.name, runtimeFunction);
			else {
				var mapParts = WasmModuleSupport.mapNativeParts(native.name);
				if (mapParts != null)
					functions.set(native.name, addMapRuntimeFunction(module, functions, native.name, mapParts.mapName, mapParts.operation, allocator));
				else
					switch native.name {
						case "__string_length":
							functions.set(native.name,
								module.addFunction(WasmFunctionBuilder.fromRaw(native.name, {parameters: [I32], results: [I32]}, [],
									[LocalGet(0), I32Load(WasmLayout.STRING_LENGTH_OFFSET), Return])));
						case "__string_char_code_at":
							functions.set(native.name, addStringCharCodeAt(module, native.name));
						case "__string_concat":
							functions.set(native.name, addStringConcat(module, native.name, allocator));
						case "__string_to_lower_case":
							functions.set(native.name, addStringCase(module, native.name, allocator, true));
						case "__string_to_upper_case":
							functions.set(native.name, addStringCase(module, native.name, allocator, false));
						case "__string_index_of":
							functions.set(native.name, addStringIndexOf(module, native.name));
						case "__string_substring":
							if (!functions.exists(native.name))
								functions.set(native.name, addStringSubstring(module, native.name, allocator));
						case "__string_char_at":
							functions.set(native.name, addStringCharAt(module, native.name, allocator));
						case "__string_from_char_code":
							functions.set(native.name, addStringFromCharCode(module, native.name, allocator));
						case "__string_equal":
							functions.set(native.name, addStringEqual(module, native.name));
						case "__string_compare_full":
							functions.set(native.name, addStringCompareFull(module, native.name));
						case "__string_split":
							var substring = functions.get("__string_substring");
							if (substring == null) {
								substring = addStringSubstring(module, "__string_substring", allocator);
								functions.set("__string_substring", substring);
							}
							functions.set(native.name, addStringSplit(module, native.name, allocator, substring));
						case "__std_int_f64":
							functions.set(native.name,
								module.addFunction(WasmFunctionBuilder.fromRaw(native.name, {parameters: [F64], results: [I32]}, [],
									[LocalGet(0), I32TruncF64S, Return])));
						case "__std_int_dynamic":
							functions.set(native.name, addDynamicInt(module, native.name));
						case "__reflect_is_object":
							functions.set(native.name, addDynamicIsObject(module, native.name, program));
						case "__std_string":
							functions.set(native.name, addDynamicString(module, native.name, allocator, strings, program));
						case "__dynamic_equal":
							// Emitted after the native scan so the string helper has an index.
						case "__std_is_of_type", "__exception_matches":
							functions.set(native.name, addTypeTest(module, native.name, program));
						case "__array_copy_i32", "__array_copy_bool", "__array_copy_ref", "__array_copy_bytes":
							functions.set(native.name, WasmLinearArrays.addArrayCopy(module, native.name, 4, allocator));
						case "__array_copy_f64", "__array_copy_i64":
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
						case "__array_index_of_i64":
							functions.set(native.name, WasmLinearArrays.addArrayIndexOf(module, native.name, 8, I64, null));
						case "__array_slice_i32", "__array_slice_bool", "__array_slice_ref", "__array_slice_bytes":
							functions.set(native.name, WasmLinearArrays.addArraySlice(module, native.name, 4, allocator));
						case "__array_slice_f64", "__array_slice_i64":
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
						case "__array_concat_f64", "__array_concat_i64":
							functions.set(native.name, WasmLinearArrays.addArrayConcat(module, native.name, 8, allocator));
						case "__array_push_i32", "__array_push_bool", "__array_push_ref", "__array_push_bytes":
							functions.set(native.name, WasmLinearArrays.addArrayPush(module, native.name, 4, I32, allocator));
						case "__array_push_f64", "__array_push_i64":
							functions.set(native.name,
								WasmLinearArrays.addArrayPush(module, native.name, 8, native.name == "__array_push_i64" ? I64 : F64, allocator));
						case "__array_pop_i32", "__array_pop_bool", "__array_pop_ref", "__array_pop_bytes":
							functions.set(native.name, WasmLinearArrays.addArrayPop(module, native.name, 4, I32));
						case "__array_pop_f64", "__array_pop_i64":
							functions.set(native.name, WasmLinearArrays.addArrayPop(module, native.name, 8, native.name == "__array_pop_i64" ? I64 : F64));
						case "__array_unshift_i32", "__array_unshift_bool", "__array_unshift_ref", "__array_unshift_bytes":
							functions.set(native.name, WasmLinearArrays.addArrayUnshift(module, native.name, 4, I32, allocator));
						case "__array_unshift_f64", "__array_unshift_i64":
							functions.set(native.name,
								WasmLinearArrays.addArrayUnshift(module, native.name, 8, native.name == "__array_unshift_i64" ? I64 : F64, allocator));
						case "__array_insert_i32", "__array_insert_bool", "__array_insert_ref", "__array_insert_bytes":
							functions.set(native.name, WasmLinearArrays.addArrayInsert(module, native.name, 4, I32, allocator));
						case "__array_insert_f64", "__array_insert_i64":
							functions.set(native.name,
								WasmLinearArrays.addArrayInsert(module, native.name, 8, native.name == "__array_insert_i64" ? I64 : F64, allocator));
						case "__array_shift_i32", "__array_shift_bool", "__array_shift_ref", "__array_shift_bytes":
							functions.set(native.name, WasmLinearArrays.addArrayShift(module, native.name, 4, I32));
						case "__array_shift_f64", "__array_shift_i64":
							functions.set(native.name, WasmLinearArrays.addArrayShift(module, native.name, 8, native.name == "__array_shift_i64" ? I64 : F64));
						case "__array_resize_i32", "__array_resize_bool", "__array_resize_ref", "__array_resize_bytes":
							functions.set(native.name, WasmLinearArrays.addArrayResize(module, native.name, 4, I32, allocator));
						case "__array_resize_f64", "__array_resize_i64":
							functions.set(native.name,
								WasmLinearArrays.addArrayResize(module, native.name, 8, native.name == "__array_resize_i64" ? I64 : F64, allocator));
						case "__array_remove_i32", "__array_remove_bool", "__array_remove_ref":
							functions.set(native.name, WasmLinearArrays.addArrayRemove(module, native.name, 4, I32, null));
						case "__array_remove_bytes":
							var stringEqual = functions.get("__string_equal");
							if (stringEqual == null) {
								stringEqual = addStringEqual(module, "__string_equal");
								functions.set("__string_equal", stringEqual);
							}
							functions.set(native.name, WasmLinearArrays.addArrayRemove(module, native.name, 4, I32, stringEqual));
						case "__array_remove_f64", "__array_remove_i64":
							functions.set(native.name,
								WasmLinearArrays.addArrayRemove(module, native.name, 8, native.name == "__array_remove_i64" ? I64 : F64, null));
						case "__array_reverse_i32", "__array_reverse_bool", "__array_reverse_ref", "__array_reverse_bytes":
							functions.set(native.name, WasmLinearArrays.addArrayReverse(module, native.name, 4, I32));
						case "__array_reverse_f64", "__array_reverse_i64":
							functions.set(native.name,
								WasmLinearArrays.addArrayReverse(module, native.name, 8, native.name == "__array_reverse_i64" ? I64 : F64));
						case "__array_splice_i32", "__array_splice_bool", "__array_splice_ref", "__array_splice_bytes":
							functions.set(native.name, WasmLinearArrays.addArraySplice(module, native.name, 4, allocator));
						case "__array_splice_f64", "__array_splice_i64":
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
		for (native in program.natives)
			if (native.symbol == "native_callback_create") {
				var callbackAllocator = addBytesAlloc(module, "__haxeon_callback_alloc_bytes", allocator);
				functions.set("__haxeon_callback_alloc_bytes", callbackAllocator);
				module.exports.push({name: "__haxeon_callback_alloc_bytes", functionIndex: callbackAllocator});
				break;
			}
	}

	/** Lower the stable haxeon_runtime symbol names used by generated HXI and stdlib code. */
	static function addRuntimeNativeFunction(module:WasmModule, native:compiler.ir.Ir.IrNative, allocator:Int, bytesDataPointer:Int,
			outputReserve:Int):Null<Int> {
		return switch native.symbol {
			case "__math_is_finite", "__math_pow", "__math_cos", "__math_sin", "__math_tan", "__math_fmod", "__math_round", "__math_ceil", "__math_floor",
				"__sys_print", "__sys_args", "__date_now", "__date_get_time":
				runtimeImportIndex(module, native);
			case "__math_is_nan": addMathIsNaN(module, native.name);
			case "sys_time", "sys_cpu_time", "sys_thread_cpu_time", "sys_process_memory", "sys_getpid", "sys_sleep", "sys_get_char", "sys_exit",
				"native_callback_create", "native_callback_close", "native_callback_error_kind", "native_callback_take_error":
				runtimeImportIndex(module, native);
			case "__bytes_alloc": addBytesAlloc(module, native.name, allocator);
			case "__runtime_string_from_ascii": addStringFromAscii(module, native.name, allocator);
			case "__bytes_of_string": addBytesFromString(module, native.name, allocator);
			case "__bytes_view": addBytesView(module, native.name, allocator);
			case "__bytes_sub", "structSlice": addBytesSlice(module, native.name, allocator, bytesDataPointer);
			case "__bytes_length": addBytesLength(module, native.name);
			case "__bytes_compare": addBytesCompare(module, native.name, bytesDataPointer);
			case "__bytes_get", "getU8": addBytesLoad(module, native.name, I32, I32Load8U(0), bytesDataPointer);
			case "getI8": addBytesLoad(module, native.name, I32, I32Load8S(0), bytesDataPointer);
			case "getU16": addBytesLoad(module, native.name, I32, I32Load16U(0), bytesDataPointer);
			case "getI16": addBytesLoad(module, native.name, I32, I32Load16S(0), bytesDataPointer);
			case "__bytes_get_i32", "getI32": addBytesLoad(module, native.name, I32, I32Load(0), bytesDataPointer);
			case "getI64": addBytesLoad(module, native.name, I64, I64Load(0), bytesDataPointer);
			case "getF32": addBytesLoad(module, native.name, F64, F32Load(0), bytesDataPointer, [F64PromoteF32]);
			case "getF64": addBytesLoad(module, native.name, F64, F64Load(0), bytesDataPointer);
			case "__bytes_set", "setI8", "setU8": addBytesStore(module, native.name, I32, I32Store8(0), bytesDataPointer);
			case "__bytes_set_i32", "setI32": addBytesStore(module, native.name, I32, I32Store(0), bytesDataPointer);
			case "setI16", "setU16": addBytesStore(module, native.name, I32, I32Store16(0), bytesDataPointer);
			case "setI64": addBytesStore(module, native.name, I64, I64Store(0), bytesDataPointer);
			case "setF32": addBytesStore(module, native.name, F64, F32Store(0), bytesDataPointer, [F32DemoteF64]);
			case "setF64": addBytesStore(module, native.name, F64, F64Store(0), bytesDataPointer);
			case "__bytes_get_data": addBytesData(module, native.name, bytesDataPointer);
			case "__bytes_to_string": addBytesToString(module, native.name, allocator, bytesDataPointer);
			case "__bytes_get_string": addBytesSlice(module, native.name, allocator, bytesDataPointer);
			case "__string_from_bytes": addBytesPrefix(module, native.name, allocator, bytesDataPointer);
			case "__bytes_input_new": addBytesInputNew(module, native.name, allocator, bytesDataPointer);
			case "__bytes_input_position": addBytesStreamFieldLoad(module, native.name, WasmLayout.BYTES_STREAM_POSITION_OFFSET);
			case "__bytes_input_big_endian": addBytesStreamFieldLoad(module, native.name, WasmLayout.BYTES_STREAM_ENDIAN_OFFSET);
			case "__bytes_input_set_big_endian": addBytesStreamFieldStore(module, native.name, WasmLayout.BYTES_STREAM_ENDIAN_OFFSET);
			case "__bytes_input_read_byte": addBytesInputReadByte(module, native.name, bytesDataPointer);
			case "__bytes_input_read_i32": addBytesInputReadI32(module, native.name, bytesDataPointer);
			case "__bytes_input_read_f64": addBytesInputReadF64(module, native.name, bytesDataPointer);
			case "__bytes_input_read_string": addBytesInputReadString(module, native.name, allocator, bytesDataPointer);
			case "__bytes_input_read": addBytesInputRead(module, native.name, allocator, bytesDataPointer);
			case "__bytes_output_new": addBytesOutputNew(module, native.name, allocator);
			case "__bytes_output_big_endian": addBytesStreamFieldLoad(module, native.name, WasmLayout.BYTES_STREAM_ENDIAN_OFFSET);
			case "__bytes_output_set_big_endian": addBytesStreamFieldStore(module, native.name, WasmLayout.BYTES_STREAM_ENDIAN_OFFSET);
			case "__bytes_output_write_byte": addBytesOutputWriteByte(module, native.name, outputReserve);
			case "__bytes_output_write_i32": addBytesOutputWriteI32(module, native.name, outputReserve);
			case "__bytes_output_write_f64": addBytesOutputWriteF64(module, native.name, outputReserve);
			case "__bytes_output_write_string": addBytesOutputWriteString(module, native.name, outputReserve, bytesDataPointer);
			case "__bytes_output_write": addBytesOutputWrite(module, native.name, outputReserve, bytesDataPointer);
			case "__bytes_output_write_range": addBytesOutputWriteRange(module, native.name, outputReserve, bytesDataPointer);
			case "__bytes_output_get_bytes": addBytesOutputGetBytes(module, native.name, allocator, bytesDataPointer);
			case "structCopy": addStructCopy(module, native.name, bytesDataPointer);
			case "structCopyPointer": addStructCopyPointer(module, native.name, allocator, bytesDataPointer);
			case "structSetBorrowedBytes": addStructSetBorrowedBytes(module, native.name, bytesDataPointer);
			case "structWithRoots": addStructWithRoots(module, native.name, allocator, bytesDataPointer);
			case "structGetRoots": addStructGetRoots(module, native.name);
			case "structUtf8Copy": addStructUtf8Copy(module, native.name, allocator, bytesDataPointer);
			case "structGetPointer": addStructGetPointer(module, native.name, bytesDataPointer);
			case "structSetPointer": addStructSetPointer(module, native.name, bytesDataPointer);
			case "structGetUtf8": addStructGetUtf8(module, native.name, allocator, bytesDataPointer);
			case "structSetUtf8": addStructSetUtf8(module, native.name, allocator, bytesDataPointer);
			default: null;
		};
	}

	static function addBytesAlloc(module:WasmModule, name:String, allocator:Int):Int {
		return module.addFunction(WasmFunctionBuilder.fromRaw(name, {parameters: [I32], results: [I32]}, [{type: I32}], [
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			Call(allocator),
			LocalSet(1),
			LocalGet(1),
			I32Const(WasmModuleSupport.typeId(Bytes)),
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

	static function addStringFromAscii(module:WasmModule, name:String, allocator:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32, I32], results: [I32]}),
			chars = builder.parameter("chars", 0),
			offset = builder.parameter("offset", 1),
			length = builder.parameter("length", 2),
			arrayLength = builder.local("arrayLength", I32),
			data = builder.local("data", I32),
			result = builder.local("result", I32),
			index = builder.local("index", I32);
		builder.localGet(chars);
		builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localSet(arrayLength);
		for (value in [offset, length]) {
			builder.localGet(value);
			builder.i32Const(0);
			builder.emit(I32LtS);
			builder.ifElse(function(builder) builder.emit(Unreachable), function(_) {});
		}
		builder.localGet(arrayLength);
		builder.localGet(length);
		builder.i32Sub();
		builder.localGet(offset);
		builder.emit(I32LtS);
		builder.ifElse(function(builder) builder.emit(Unreachable), function(_) {});
		builder.localGet(chars);
		builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
		builder.localSet(data);
		builder.localGet(length);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.call(builder.functionRef(allocator));
		builder.localSet(result);
		builder.localGet(result);
		builder.i32Const(WasmModuleSupport.typeId(Bytes));
		builder.emit(I32Store(0));
		builder.localGet(result);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localGet(result);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.i32Const(0);
		builder.localSet(index);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(index);
				builder.localGet(length);
				builder.emit(I32LtS);
				builder.ifElse(function(builder) {
					builder.localGet(result);
					builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
					builder.i32Add();
					builder.localGet(index);
					builder.i32Add();
					builder.localGet(data);
					builder.localGet(offset);
					builder.localGet(index);
					builder.i32Add();
					builder.i32Const(4);
					builder.emit(I32Mul);
					builder.i32Add();
					builder.emit(I32Load(0));
					builder.emit(I32Store8(0));
					builder.localGet(index);
					builder.i32Const(1);
					builder.i32Add();
					builder.localSet(index);
					builder.emit(Br(1));
				}, function(builder) builder.emit(Br(0)));
			});
		});
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addBytesFromString(module:WasmModule, name:String, allocator:Int):Int {
		return module.addFunction(WasmFunctionBuilder.fromRaw(name, {parameters: [I32], results: [I32]}, [{type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.STRING_LENGTH_OFFSET),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			Call(allocator),
			LocalSet(1),
			LocalGet(1),
			I32Const(WasmModuleSupport.typeId(Bytes)),
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
		return module.addFunction(WasmFunctionBuilder.fromRaw(name, {parameters: [I32], results: [I32]}, [],
			[LocalGet(0), I32Load(WasmLayout.STRING_LENGTH_OFFSET), Return]));

	static function addBytesCompare(module:WasmModule, name:String, bytesDataPointer:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: [I32]}),
			left = builder.parameter("left", 0),
			right = builder.parameter("right", 1),
			leftLength = builder.local("leftLength", I32),
			rightLength = builder.local("rightLength", I32),
			index = builder.local("index", I32),
			result = builder.local("result", I32),
			leftByte = builder.local("leftByte", I32),
			rightByte = builder.local("rightByte", I32);
		builder.localGet(left);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localSet(leftLength);
		builder.localGet(right);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localSet(rightLength);
		builder.i32Const(0);
		builder.localSet(index);
		builder.i32Const(0);
		builder.localSet(result);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(index);
				builder.localGet(leftLength);
				builder.emit(I32LtS);
				builder.i32Eqz();
				builder.localGet(index);
				builder.localGet(rightLength);
				builder.emit(I32LtS);
				builder.i32Eqz();
				builder.emit(I32Or);
				builder.emit(BrIf(1));
				builder.localGet(left);
				builder.call(builder.functionRef(bytesDataPointer));
				builder.localGet(index);
				builder.i32Add();
				builder.emit(I32Load8U(0));
				builder.localSet(leftByte);
				builder.localGet(right);
				builder.call(builder.functionRef(bytesDataPointer));
				builder.localGet(index);
				builder.i32Add();
				builder.emit(I32Load8U(0));
				builder.localSet(rightByte);
				builder.localGet(leftByte);
				builder.localGet(rightByte);
				builder.emit(I32Eq);
				builder.i32Eqz();
				builder.if_(function(builder) {
					builder.localGet(leftByte);
					builder.localGet(rightByte);
					builder.emit(I32LtS);
					builder.ifElse(function(builder) {
						builder.i32Const(-1);
						builder.localSet(result);
					}, function(builder) {
						builder.i32Const(1);
						builder.localSet(result);
					});
					builder.emit(Br(2));
				});
				builder.localGet(index);
				builder.i32Const(1);
				builder.i32Add();
				builder.localSet(index);
				builder.emit(Br(0));
			});
		});
		builder.localGet(result);
		builder.i32Eqz();
		builder.if_(function(builder) {
			builder.localGet(leftLength);
			builder.localGet(rightLength);
			builder.emit(I32LtS);
			builder.ifElse(function(builder) {
				builder.i32Const(-1);
				builder.localSet(result);
			}, function(builder) {
				builder.localGet(rightLength);
				builder.localGet(leftLength);
				builder.emit(I32LtS);
				builder.if_(function(builder) {
					builder.i32Const(1);
					builder.localSet(result);
				});
			});
		});
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addBytesDataPointer(module:WasmModule):Int {
		var builder = new WasmFunctionBuilder("__haxeon_bytes_data_pointer", {parameters: [I32], results: [I32]}),
			bytes = builder.parameter("bytes", 0),
			data = builder.local("data", I32);
		builder.localGet(bytes);
		builder.emit(I32Load(WasmLayout.BYTES_VIEW_MARKER_OFFSET));
		builder.i32Const(WasmLayout.BYTES_VIEW_MAGIC);
		builder.emit(I32Eq);
		builder.ifElse(function(builder) {
			builder.localGet(bytes);
			builder.emit(I32Load(WasmLayout.BYTES_VIEW_OWNER_OFFSET));
			builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
			builder.i32Add();
			builder.localGet(bytes);
			builder.emit(I32Load(WasmLayout.BYTES_VIEW_DATA_OFFSET));
			builder.i32Add();
			builder.localSet(data);
		}, function(builder) {
			builder.localGet(bytes);
			builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
			builder.i32Add();
			builder.localSet(data);
		});
		builder.localGet(data);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addBytesData(module:WasmModule, name:String, bytesDataPointer:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [I32]}),
			bytes = builder.parameter("bytes", 0);
		builder.localGet(bytes);
		builder.call(builder.functionRef(bytesDataPointer));
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addBytesInputNew(module:WasmModule, name:String, allocator:Int, bytesDataPointer:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [I32]}),
			bytes = builder.parameter("bytes", 0),
			result = builder.local("result", I32),
			length = builder.local("length", I32),
			snapshot = builder.local("snapshot", I32);
		builder.localGet(bytes);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localSet(length);
		builder.i32Const(WasmLayout.BYTES_STREAM_SIZE);
		builder.call(builder.functionRef(allocator));
		builder.localSet(result);
		builder.localGet(length);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.call(builder.functionRef(allocator));
		builder.localSet(snapshot);
		builder.localGet(snapshot);
		builder.i32Const(WasmModuleSupport.typeId(Bytes));
		builder.emit(I32Store(0));
		builder.localGet(snapshot);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localGet(snapshot);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.localGet(snapshot);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.localGet(bytes);
		builder.call(builder.functionRef(bytesDataPointer));
		builder.localGet(length);
		builder.emit(MemoryCopy);
		builder.localGet(result);
		builder.i32Const(WasmModuleSupport.typeId(Abstract("realtime_bytes_input")));
		builder.emit(I32Store(0));
		builder.localGet(result);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.BYTES_STREAM_LENGTH_OFFSET));
		builder.localGet(result);
		builder.i32Const(0);
		builder.emit(I32Store(WasmLayout.BYTES_STREAM_POSITION_OFFSET));
		builder.localGet(result);
		builder.localGet(snapshot);
		builder.emit(I32Store(WasmLayout.BYTES_STREAM_DATA_OFFSET));
		builder.localGet(result);
		builder.i32Const(1);
		builder.emit(I32Store(WasmLayout.BYTES_STREAM_ENDIAN_OFFSET));
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addBytesStreamFieldLoad(module:WasmModule, name:String, offset:Int):Int
		return module.addFunction(WasmFunctionBuilder.fromRaw(name, {parameters: [I32], results: [I32]}, [], [LocalGet(0), I32Load(offset), Return]));

	static function addBytesStreamFieldStore(module:WasmModule, name:String, offset:Int):Int
		return module.addFunction(WasmFunctionBuilder.fromRaw(name, {parameters: [I32, I32], results: []}, [],
			[LocalGet(0), LocalGet(1), I32Store(offset), Return]));

	static function addBytesInputReadByte(module:WasmModule, name:String, bytesDataPointer:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [I32]}),
			input = builder.parameter("input", 0),
			position = builder.local("position", I32),
			bytes = builder.local("bytes", I32),
			result = builder.local("result", I32);
		inputReadCheckConstant(builder, input, 1);
		loadInputState(builder, input, position, bytes);
		emitInputByte(builder, bytes, position, 0, bytesDataPointer, result);
		inputAdvanceConstant(builder, input, position, 1);
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addBytesInputReadI32(module:WasmModule, name:String, bytesDataPointer:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [I32]}),
			input = builder.parameter("input", 0),
			position = builder.local("position", I32),
			bytes = builder.local("bytes", I32),
			endian = builder.local("endian", I32),
			result = builder.local("result", I32),
			byteLocals = [for (_ in 0...4) builder.local("byte_" + _, I32)];
		inputReadCheckConstant(builder, input, 4);
		loadInputState(builder, input, position, bytes);
		builder.localGet(input);
		builder.emit(I32Load(WasmLayout.BYTES_STREAM_ENDIAN_OFFSET));
		builder.localSet(endian);
		for (index in 0...4)
			emitInputByte(builder, bytes, position, index, bytesDataPointer, byteLocals[index]);
		builder.localGet(endian);
		builder.ifElse(function(builder) {
			emitCombineI32(builder, byteLocals, [24, 16, 8, 0]);
			builder.localSet(result);
		}, function(builder) {
			emitCombineI32(builder, byteLocals, [0, 8, 16, 24]);
			builder.localSet(result);
		});
		inputAdvanceConstant(builder, input, position, 4);
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addBytesInputReadF64(module:WasmModule, name:String, bytesDataPointer:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [F64]}),
			input = builder.parameter("input", 0),
			position = builder.local("position", I32),
			bytes = builder.local("bytes", I32),
			endian = builder.local("endian", I32),
			result = builder.local("result", F64),
			bits = builder.local("bits", I64),
			byteLocals = [for (_ in 0...8) builder.local("byte_" + _, I32)];
		inputReadCheckConstant(builder, input, 8);
		loadInputState(builder, input, position, bytes);
		builder.localGet(input);
		builder.emit(I32Load(WasmLayout.BYTES_STREAM_ENDIAN_OFFSET));
		builder.localSet(endian);
		for (index in 0...8)
			emitInputByte(builder, bytes, position, index, bytesDataPointer, byteLocals[index]);
		builder.localGet(endian);
		builder.ifElse(function(builder) {
			emitCombineI64(builder, byteLocals, [56, 48, 40, 32, 24, 16, 8, 0]);
			builder.localSet(bits);
		}, function(builder) {
			emitCombineI64(builder, byteLocals, [0, 8, 16, 24, 32, 40, 48, 56]);
			builder.localSet(bits);
		});
		builder.localGet(bits);
		builder.emit(F64ReinterpretI64);
		builder.localSet(result);
		inputAdvanceConstant(builder, input, position, 8);
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addBytesInputReadString(module:WasmModule, name:String, allocator:Int, bytesDataPointer:Int):Int
		return addBytesInputReadBuffer(module, name, allocator, bytesDataPointer);

	static function addBytesInputRead(module:WasmModule, name:String, allocator:Int, bytesDataPointer:Int):Int
		return addBytesInputReadBuffer(module, name, allocator, bytesDataPointer);

	static function addBytesInputReadBuffer(module:WasmModule, name:String, allocator:Int, bytesDataPointer:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: [I32]}),
			input = builder.parameter("input", 0),
			length = builder.parameter("length", 1),
			position = builder.local("position", I32),
			bytes = builder.local("bytes", I32),
			result = builder.local("result", I32);
		inputReadCheckLocal(builder, input, length);
		loadInputState(builder, input, position, bytes);
		builder.localGet(length);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.call(builder.functionRef(allocator));
		builder.localSet(result);
		builder.localGet(result);
		builder.i32Const(WasmModuleSupport.typeId(Bytes));
		builder.emit(I32Store(0));
		builder.localGet(result);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localGet(result);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.localGet(result);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.localGet(bytes);
		builder.call(builder.functionRef(bytesDataPointer));
		builder.localGet(position);
		builder.i32Add();
		builder.localGet(length);
		builder.emit(MemoryCopy);
		inputAdvanceLocal(builder, input, position, length);
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addBytesOutputNew(module:WasmModule, name:String, allocator:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [], results: [I32]}),
			result = builder.local("result", I32);
		builder.i32Const(WasmLayout.BYTES_STREAM_SIZE);
		builder.call(builder.functionRef(allocator));
		builder.localSet(result);
		builder.localGet(result);
		builder.i32Const(WasmModuleSupport.typeId(Abstract("realtime_bytes_output")));
		builder.emit(I32Store(0));
		for (field in [
			WasmLayout.BYTES_STREAM_LENGTH_OFFSET,
			WasmLayout.BYTES_STREAM_CAPACITY_OFFSET,
			WasmLayout.BYTES_STREAM_DATA_OFFSET
		]) {
			builder.localGet(result);
			builder.i32Const(0);
			builder.emit(I32Store(field));
		}
		builder.localGet(result);
		builder.i32Const(1);
		builder.emit(I32Store(WasmLayout.BYTES_STREAM_ENDIAN_OFFSET));
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addBytesOutputWriteByte(module:WasmModule, name:String, outputReserve:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: []}),
			output = builder.parameter("output", 0),
			value = builder.parameter("value", 1),
			data = builder.local("data", I32);
		reserveOutputConstant(builder, output, 1, outputReserve, data);
		emitOutputByte(builder, data, output, value, 0, 0);
		outputAdvanceConstant(builder, output, 1);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addBytesOutputWriteI32(module:WasmModule, name:String, outputReserve:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: []}),
			output = builder.parameter("output", 0),
			value = builder.parameter("value", 1),
			data = builder.local("data", I32),
			endian = builder.local("endian", I32);
		reserveOutputConstant(builder, output, 4, outputReserve, data);
		builder.localGet(output);
		builder.emit(I32Load(WasmLayout.BYTES_STREAM_ENDIAN_OFFSET));
		builder.localSet(endian);
		builder.localGet(endian);
		builder.ifElse(function(builder) {
			for (index in 0...4)
				emitOutputByte(builder, data, output, value, (3 - index) * 8, index);
		}, function(builder) {
			for (index in 0...4)
				emitOutputByte(builder, data, output, value, index * 8, index);
		});
		outputAdvanceConstant(builder, output, 4);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addBytesOutputWriteF64(module:WasmModule, name:String, outputReserve:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, F64], results: []}),
			output = builder.parameter("output", 0),
			value = builder.parameter("value", 1),
			data = builder.local("data", I32),
			bits = builder.local("bits", I64),
			endian = builder.local("endian", I32);
		reserveOutputConstant(builder, output, 8, outputReserve, data);
		builder.localGet(value);
		builder.emit(I64ReinterpretF64);
		builder.localSet(bits);
		builder.localGet(output);
		builder.emit(I32Load(WasmLayout.BYTES_STREAM_ENDIAN_OFFSET));
		builder.localSet(endian);
		builder.localGet(endian);
		builder.ifElse(function(builder) {
			for (index in 0...8)
				emitOutputByteI64(builder, data, output, bits, (7 - index) * 8, index);
		}, function(builder) {
			for (index in 0...8)
				emitOutputByteI64(builder, data, output, bits, index * 8, index);
		});
		outputAdvanceConstant(builder, output, 8);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addBytesOutputWriteString(module:WasmModule, name:String, outputReserve:Int, bytesDataPointer:Int):Int
		return addBytesOutputWriteBuffer(module, name, outputReserve, bytesDataPointer);

	static function addBytesOutputWrite(module:WasmModule, name:String, outputReserve:Int, bytesDataPointer:Int):Int
		return addBytesOutputWriteBuffer(module, name, outputReserve, bytesDataPointer);

	static function addBytesOutputWriteBuffer(module:WasmModule, name:String, outputReserve:Int, bytesDataPointer:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: []}),
			output = builder.parameter("output", 0),
			bytes = builder.parameter("bytes", 1),
			length = builder.local("length", I32),
			data = builder.local("data", I32),
			source = builder.local("source", I32);
		builder.localGet(bytes);
		builder.i32Eqz();
		builder.if_(function(builder) builder.return_());
		builder.localGet(bytes);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localSet(length);
		reserveOutputLocal(builder, output, length, outputReserve, data);
		builder.localGet(bytes);
		builder.call(builder.functionRef(bytesDataPointer));
		builder.localSet(source);
		builder.localGet(data);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.localGet(output);
		builder.emit(I32Load(WasmLayout.BYTES_STREAM_LENGTH_OFFSET));
		builder.i32Add();
		builder.localGet(source);
		builder.localGet(length);
		builder.emit(MemoryCopy);
		outputAdvanceLocal(builder, output, length);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addBytesOutputWriteRange(module:WasmModule, name:String, outputReserve:Int, bytesDataPointer:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32, I32, I32], results: [I32]}),
			output = builder.parameter("output", 0),
			bytes = builder.parameter("bytes", 1),
			offset = builder.parameter("offset", 2),
			length = builder.parameter("length", 3),
			data = builder.local("data", I32),
			source = builder.local("source", I32);
		bytesRangeCheck(builder, bytes, offset, length);
		reserveOutputLocal(builder, output, length, outputReserve, data);
		builder.localGet(bytes);
		builder.call(builder.functionRef(bytesDataPointer));
		builder.localSet(source);
		builder.localGet(data);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.localGet(output);
		builder.emit(I32Load(WasmLayout.BYTES_STREAM_LENGTH_OFFSET));
		builder.i32Add();
		builder.localGet(source);
		builder.localGet(offset);
		builder.i32Add();
		builder.localGet(length);
		builder.emit(MemoryCopy);
		outputAdvanceLocal(builder, output, length);
		builder.localGet(length);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addBytesOutputGetBytes(module:WasmModule, name:String, allocator:Int, bytesDataPointer:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [I32]}),
			output = builder.parameter("output", 0),
			length = builder.local("length", I32),
			data = builder.local("data", I32),
			result = builder.local("result", I32);
		builder.localGet(output);
		builder.emit(I32Load(WasmLayout.BYTES_STREAM_LENGTH_OFFSET));
		builder.localSet(length);
		builder.localGet(length);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.call(builder.functionRef(allocator));
		builder.localSet(result);
		builder.localGet(result);
		builder.i32Const(WasmModuleSupport.typeId(Bytes));
		builder.emit(I32Store(0));
		builder.localGet(result);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localGet(result);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.localGet(output);
		builder.emit(I32Load(WasmLayout.BYTES_STREAM_DATA_OFFSET));
		builder.localSet(data);
		builder.localGet(result);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.localGet(data);
		builder.call(builder.functionRef(bytesDataPointer));
		builder.localGet(length);
		builder.emit(MemoryCopy);
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addBytesOutputReserve(module:WasmModule, allocator:Int, bytesDataPointer:Int):Int {
		var builder = new WasmFunctionBuilder("__haxeon_bytes_output_reserve", {parameters: [I32, I32], results: [I32]}),
			output = builder.parameter("output", 0),
			extra = builder.parameter("extra", 1),
			length = builder.local("length", I32),
			capacity = builder.local("capacity", I32),
			data = builder.local("data", I32),
			required = builder.local("required", I32),
			newCapacity = builder.local("newCapacity", I32),
			newData = builder.local("newData", I32);
		loadStreamField(builder, output, WasmLayout.BYTES_STREAM_LENGTH_OFFSET, length);
		loadStreamField(builder, output, WasmLayout.BYTES_STREAM_CAPACITY_OFFSET, capacity);
		loadStreamField(builder, output, WasmLayout.BYTES_STREAM_DATA_OFFSET, data);
		builder.localGet(length);
		builder.localGet(extra);
		builder.emit(I32Add);
		builder.localSet(required);
		builder.localGet(required);
		builder.localGet(capacity);
		builder.emit(I32LeS);
		builder.i32Eqz();
		builder.if_(function(builder) {
			builder.localGet(capacity);
			builder.i32Const(2);
			builder.emit(I32Mul);
			builder.localSet(newCapacity);
			builder.localGet(newCapacity);
			builder.localGet(required);
			builder.emit(I32LtS);
			builder.if_(function(builder) {
				builder.localGet(required);
				builder.localSet(newCapacity);
			});
			builder.localGet(newCapacity);
			builder.i32Const(8);
			builder.emit(I32LtS);
			builder.if_(function(builder) {
				builder.i32Const(8);
				builder.localSet(newCapacity);
			});
			builder.localGet(newCapacity);
			builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
			builder.i32Add();
			builder.call(builder.functionRef(allocator));
			builder.localSet(newData);
			builder.localGet(newData);
			builder.i32Const(WasmModuleSupport.typeId(Bytes));
			builder.emit(I32Store(0));
			builder.localGet(newData);
			builder.localGet(length);
			builder.emit(I32Store(WasmLayout.STRING_LENGTH_OFFSET));
			builder.localGet(newData);
			builder.localGet(newCapacity);
			builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
			builder.localGet(newData);
			builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
			builder.i32Add();
			builder.localGet(data);
			builder.call(builder.functionRef(bytesDataPointer));
			builder.localGet(length);
			builder.emit(MemoryCopy);
			builder.localGet(output);
			builder.localGet(newData);
			builder.emit(I32Store(WasmLayout.BYTES_STREAM_DATA_OFFSET));
			builder.localGet(output);
			builder.localGet(newCapacity);
			builder.emit(I32Store(WasmLayout.BYTES_STREAM_CAPACITY_OFFSET));
		});
		builder.localGet(output);
		builder.emit(I32Load(WasmLayout.BYTES_STREAM_DATA_OFFSET));
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function loadStreamField(builder:WasmFunctionBuilder, stream:WasmLocalRef, offset:Int, destination:WasmLocalRef):Void {
		builder.localGet(stream);
		builder.emit(I32Load(offset));
		builder.localSet(destination);
	}

	static function inputReadCheckConstant(builder:WasmFunctionBuilder, input:WasmLocalRef, length:Int):Void {
		builder.i32Const(length);
		builder.i32Const(0);
		builder.emit(I32LtS);
		builder.if_(function(builder) builder.emit(Unreachable));
		builder.localGet(input);
		builder.emit(I32Load(WasmLayout.BYTES_STREAM_LENGTH_OFFSET));
		builder.i32Const(length);
		builder.emit(I32Sub);
		builder.localGet(input);
		builder.emit(I32Load(WasmLayout.BYTES_STREAM_POSITION_OFFSET));
		builder.emit(I32LtS);
		builder.if_(function(builder) builder.emit(Unreachable));
	}

	static function inputReadCheckLocal(builder:WasmFunctionBuilder, input:WasmLocalRef, length:WasmLocalRef):Void {
		builder.localGet(length);
		builder.i32Const(0);
		builder.emit(I32LtS);
		builder.if_(function(builder) builder.emit(Unreachable));
		builder.localGet(input);
		builder.emit(I32Load(WasmLayout.BYTES_STREAM_LENGTH_OFFSET));
		builder.localGet(length);
		builder.emit(I32Sub);
		builder.localGet(input);
		builder.emit(I32Load(WasmLayout.BYTES_STREAM_POSITION_OFFSET));
		builder.emit(I32LtS);
		builder.if_(function(builder) builder.emit(Unreachable));
	}

	static function loadInputState(builder:WasmFunctionBuilder, input:WasmLocalRef, position:WasmLocalRef, bytes:WasmLocalRef):Void {
		loadStreamField(builder, input, WasmLayout.BYTES_STREAM_POSITION_OFFSET, position);
		loadStreamField(builder, input, WasmLayout.BYTES_STREAM_DATA_OFFSET, bytes);
	}

	static function emitInputByte(builder:WasmFunctionBuilder, bytes:WasmLocalRef, position:WasmLocalRef, offset:Int, bytesDataPointer:Int,
			destination:WasmLocalRef):Void {
		builder.localGet(bytes);
		builder.call(builder.functionRef(bytesDataPointer));
		builder.localGet(position);
		builder.i32Const(offset);
		builder.emit(I32Add);
		builder.emit(I32Add);
		builder.emit(I32Load8U(0));
		builder.localSet(destination);
	}

	static function inputAdvanceConstant(builder:WasmFunctionBuilder, input:WasmLocalRef, position:WasmLocalRef, amount:Int):Void {
		builder.localGet(input);
		builder.localGet(position);
		builder.i32Const(amount);
		builder.emit(I32Add);
		builder.emit(I32Store(WasmLayout.BYTES_STREAM_POSITION_OFFSET));
	}

	static function inputAdvanceLocal(builder:WasmFunctionBuilder, input:WasmLocalRef, position:WasmLocalRef, amount:WasmLocalRef):Void {
		builder.localGet(input);
		builder.localGet(position);
		builder.localGet(amount);
		builder.emit(I32Add);
		builder.emit(I32Store(WasmLayout.BYTES_STREAM_POSITION_OFFSET));
	}

	static function emitCombineI32(builder:WasmFunctionBuilder, bytes:Array<WasmLocalRef>, shifts:Array<Int>):Void {
		for (index in 0...bytes.length) {
			builder.localGet(bytes[index]);
			builder.i32Const(shifts[index]);
			builder.emit(I32Shl);
			if (index > 0)
				builder.emit(I32Or);
		}
	}

	static function emitCombineI64(builder:WasmFunctionBuilder, bytes:Array<WasmLocalRef>, shifts:Array<Int>):Void {
		for (index in 0...bytes.length) {
			builder.localGet(bytes[index]);
			builder.emit(I64ExtendI32U);
			builder.emit(I64Const(shifts[index]));
			builder.emit(I64Shl);
			if (index > 0)
				builder.emit(I64Or);
		}
	}

	static function reserveOutputConstant(builder:WasmFunctionBuilder, output:WasmLocalRef, amount:Int, outputReserve:Int, data:WasmLocalRef):Void {
		builder.localGet(output);
		builder.i32Const(amount);
		builder.call(builder.functionRef(outputReserve));
		builder.localSet(data);
	}

	static function reserveOutputLocal(builder:WasmFunctionBuilder, output:WasmLocalRef, amount:WasmLocalRef, outputReserve:Int, data:WasmLocalRef):Void {
		builder.localGet(output);
		builder.localGet(amount);
		builder.call(builder.functionRef(outputReserve));
		builder.localSet(data);
	}

	static function emitOutputByte(builder:WasmFunctionBuilder, data:WasmLocalRef, output:WasmLocalRef, value:WasmLocalRef, shift:Int, offset:Int):Void {
		builder.localGet(data);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.emit(I32Add);
		builder.localGet(output);
		builder.emit(I32Load(WasmLayout.BYTES_STREAM_LENGTH_OFFSET));
		builder.emit(I32Add);
		builder.i32Const(offset);
		builder.emit(I32Add);
		builder.localGet(value);
		builder.i32Const(shift);
		builder.emit(I32ShrU);
		builder.emit(I32Store8(0));
	}

	static function emitOutputByteI64(builder:WasmFunctionBuilder, data:WasmLocalRef, output:WasmLocalRef, value:WasmLocalRef, shift:Int, offset:Int):Void {
		builder.localGet(data);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.emit(I32Add);
		builder.localGet(output);
		builder.emit(I32Load(WasmLayout.BYTES_STREAM_LENGTH_OFFSET));
		builder.emit(I32Add);
		builder.i32Const(offset);
		builder.emit(I32Add);
		builder.localGet(value);
		builder.emit(I64Const(shift));
		builder.emit(I64ShrU);
		builder.emit(I32WrapI64);
		builder.emit(I32Store8(0));
	}

	static function outputAdvanceConstant(builder:WasmFunctionBuilder, output:WasmLocalRef, amount:Int):Void {
		builder.localGet(output);
		builder.localGet(output);
		builder.emit(I32Load(WasmLayout.BYTES_STREAM_LENGTH_OFFSET));
		builder.i32Const(amount);
		builder.emit(I32Add);
		builder.emit(I32Store(WasmLayout.BYTES_STREAM_LENGTH_OFFSET));
	}

	static function outputAdvanceLocal(builder:WasmFunctionBuilder, output:WasmLocalRef, amount:WasmLocalRef):Void {
		builder.localGet(output);
		builder.localGet(output);
		builder.emit(I32Load(WasmLayout.BYTES_STREAM_LENGTH_OFFSET));
		builder.localGet(amount);
		builder.emit(I32Add);
		builder.emit(I32Store(WasmLayout.BYTES_STREAM_LENGTH_OFFSET));
	}

	static function addBytesToString(module:WasmModule, name:String, allocator:Int, bytesDataPointer:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [I32]}),
			bytes = builder.parameter("bytes", 0),
			result = builder.local("result", I32);
		builder.localGet(bytes);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.call(builder.functionRef(allocator));
		builder.localSet(result);
		builder.localGet(result);
		builder.i32Const(WasmModuleSupport.typeId(Bytes));
		builder.emit(I32Store(0));
		builder.localGet(result);
		builder.localGet(bytes);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.emit(I32Store(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localGet(result);
		builder.localGet(bytes);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.localGet(result);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.localGet(bytes);
		builder.call(builder.functionRef(bytesDataPointer));
		builder.localGet(bytes);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.emit(MemoryCopy);
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addBytesLoad(module:WasmModule, name:String, result:WasmValueType, instruction:WasmInstruction, bytesDataPointer:Int,
			?after:Array<WasmInstruction>):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: [result]}),
			bytes = builder.parameter("bytes", 0),
			offset = builder.parameter("offset", 1);
		builder.localGet(bytes);
		builder.call(builder.functionRef(bytesDataPointer));
		builder.localGet(offset);
		builder.i32Add();
		builder.emit(instruction);
		if (after != null)
			builder.emitAll(after);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addBytesStore(module:WasmModule, name:String, valueType:WasmValueType, instruction:WasmInstruction, bytesDataPointer:Int,
			?before:Array<WasmInstruction>):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32, valueType], results: []}),
			bytes = builder.parameter("bytes", 0),
			offset = builder.parameter("offset", 1),
			value = builder.parameter("value", 2);
		builder.localGet(bytes);
		builder.call(builder.functionRef(bytesDataPointer));
		builder.localGet(offset);
		builder.i32Add();
		builder.localGet(value);
		if (before != null)
			builder.emitAll(before);
		builder.emit(instruction);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addBytesSlice(module:WasmModule, name:String, allocator:Int, bytesDataPointer:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32, I32], results: [I32]}),
			bytes = builder.parameter("bytes", 0),
			offset = builder.parameter("offset", 1),
			length = builder.parameter("length", 2),
			result = builder.local("result", I32);
		bytesRangeCheck(builder, bytes, offset, length);
		builder.localGet(length);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.call(builder.functionRef(allocator));
		builder.localSet(result);
		builder.localGet(result);
		builder.i32Const(WasmModuleSupport.typeId(Bytes));
		builder.emit(I32Store(0));
		builder.localGet(result);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localGet(result);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.localGet(result);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.localGet(bytes);
		builder.call(builder.functionRef(bytesDataPointer));
		builder.localGet(offset);
		builder.i32Add();
		builder.localGet(length);
		builder.emit(MemoryCopy);
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addBytesView(module:WasmModule, name:String, allocator:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32, I32], results: [I32]}),
			bytes = builder.parameter("bytes", 0),
			offset = builder.parameter("offset", 1),
			length = builder.parameter("length", 2),
			owner = builder.local("owner", I32),
			dataOffset = builder.local("dataOffset", I32),
			roots = builder.local("roots", I32),
			result = builder.local("result", I32);
		bytesRangeCheck(builder, bytes, offset, length);
		builder.localGet(bytes);
		builder.emit(I32Load(WasmLayout.BYTES_VIEW_MARKER_OFFSET));
		builder.i32Const(WasmLayout.BYTES_VIEW_MAGIC);
		builder.emit(I32Eq);
		builder.ifElse(function(builder) {
			builder.localGet(bytes);
			builder.emit(I32Load(WasmLayout.BYTES_VIEW_OWNER_OFFSET));
			builder.localSet(owner);
			builder.localGet(bytes);
			builder.emit(I32Load(WasmLayout.BYTES_VIEW_DATA_OFFSET));
			builder.localGet(offset);
			builder.i32Add();
			builder.localSet(dataOffset);
			builder.localGet(bytes);
			builder.emit(I32Load(WasmLayout.BYTES_VIEW_ROOTS_OFFSET));
			builder.localSet(roots);
		}, function(builder) {
			builder.localGet(bytes);
			builder.localSet(owner);
			builder.localGet(offset);
			builder.localSet(dataOffset);
		});
		builder.i32Const(WasmLayout.BYTES_VIEW_SIZE);
		builder.call(builder.functionRef(allocator));
		builder.localSet(result);
		builder.localGet(result);
		builder.i32Const(WasmModuleSupport.typeId(Bytes));
		builder.emit(I32Store(0));
		builder.localGet(result);
		builder.i32Const(WasmLayout.BYTES_VIEW_MAGIC);
		builder.emit(I32Store(WasmLayout.BYTES_VIEW_MARKER_OFFSET));
		builder.localGet(result);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localGet(result);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.localGet(result);
		builder.localGet(owner);
		builder.emit(I32Store(WasmLayout.BYTES_VIEW_OWNER_OFFSET));
		builder.localGet(result);
		builder.localGet(dataOffset);
		builder.emit(I32Store(WasmLayout.BYTES_VIEW_DATA_OFFSET));
		builder.localGet(result);
		builder.localGet(roots);
		builder.emit(I32Store(WasmLayout.BYTES_VIEW_ROOTS_OFFSET));
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function bytesRangeCheck(builder:WasmFunctionBuilder, bytes:WasmLocalRef, offset:WasmLocalRef, length:WasmLocalRef):Void {
		builder.localGet(offset);
		builder.i32Const(0);
		builder.emit(I32LtS);
		builder.if_(function(builder) builder.emit(Unreachable));
		builder.localGet(length);
		builder.i32Const(0);
		builder.emit(I32LtS);
		builder.if_(function(builder) builder.emit(Unreachable));
		builder.localGet(bytes);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localGet(offset);
		builder.emit(I32LtS);
		builder.if_(function(builder) builder.emit(Unreachable));
		builder.localGet(bytes);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localGet(offset);
		builder.i32Sub();
		builder.localGet(length);
		builder.emit(I32LtS);
		builder.if_(function(builder) builder.emit(Unreachable));
	}

	static function addBytesPrefix(module:WasmModule, name:String, allocator:Int, bytesDataPointer:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: [I32]}),
			bytes = builder.parameter("bytes", 0),
			length = builder.parameter("length", 1),
			result = builder.local("result", I32);
		builder.localGet(length);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.call(builder.functionRef(allocator));
		builder.localSet(result);
		builder.localGet(result);
		builder.i32Const(WasmModuleSupport.typeId(Bytes));
		builder.emit(I32Store(0));
		builder.localGet(result);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localGet(result);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.localGet(result);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.localGet(bytes);
		builder.call(builder.functionRef(bytesDataPointer));
		builder.localGet(length);
		builder.emit(MemoryCopy);
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addStructCopy(module:WasmModule, name:String, bytesDataPointer:Int):Int {
		return module.addFunction(WasmFunctionBuilder.fromRaw(name, {parameters: [I32, I32, I32, I32], results: []}, [{type: I32}, {type: I32}], [
			LocalGet(0),
			Call(bytesDataPointer),
			LocalGet(1),
			I32Add,
			LocalSet(4),
			LocalGet(2),
			Call(bytesDataPointer),
			LocalSet(5),
			LocalGet(4),
			LocalGet(5),
			LocalGet(3),
			MemoryCopy,
			Return
		]));
	}

	static function addStructSetBorrowedBytes(module:WasmModule, name:String, bytesDataPointer:Int):Int {
		return module.addFunction(WasmFunctionBuilder.fromRaw(name, {parameters: [I32, I32, I32], results: []}, [], [
			LocalGet(0), Call(bytesDataPointer), LocalGet(1), I32Add,
			LocalGet(2), Call(bytesDataPointer), I32Store(0), Return
		]));
	}

	static function addStructWithRoots(module:WasmModule, name:String, allocator:Int, bytesDataPointer:Int):Int {
		var builder = WasmFunctionBuilder.fromRaw(name, {parameters: [I32, I32], results: [I32]}, [{type: I32}, {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.STRING_LENGTH_OFFSET),
			LocalSet(2),
			I32Const(WasmLayout.BYTES_VIEW_SIZE),
			Call(allocator),
			LocalSet(3),
			LocalGet(3),
			I32Const(WasmModuleSupport.typeId(Bytes)),
			I32Store(0),
			LocalGet(3),
			I32Const(WasmLayout.BYTES_VIEW_MAGIC),
			I32Store(WasmLayout.BYTES_VIEW_MARKER_OFFSET),
			LocalGet(3),
			LocalGet(2),
			I32Store(WasmLayout.STRING_LENGTH_OFFSET),
			LocalGet(3),
			LocalGet(2),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(3),
			LocalGet(0),
			I32Store(WasmLayout.BYTES_VIEW_OWNER_OFFSET),
			LocalGet(3),
			I32Const(0),
			I32Store(WasmLayout.BYTES_VIEW_DATA_OFFSET),
			LocalGet(3),
			LocalGet(1),
			I32Store(WasmLayout.BYTES_VIEW_ROOTS_OFFSET),
			LocalGet(3),
			Return
		]);
		return module.addFunction(builder);
	}

	static function addStructGetRoots(module:WasmModule, name:String):Int {
		return module.addFunction(WasmFunctionBuilder.fromRaw(name, {parameters: [I32], results: [I32]}, [],
			[LocalGet(0), I32Load(WasmLayout.BYTES_VIEW_ROOTS_OFFSET), Return]));
	}

	static function addStructUtf8Copy(module:WasmModule, name:String, allocator:Int, bytesDataPointer:Int):Int {
		var builder = WasmFunctionBuilder.fromRaw(name, {parameters: [I32], results: [I32]}, [{type: I32}, {type: I32}, {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.STRING_LENGTH_OFFSET),
			LocalSet(1),
			LocalGet(1),
			I32Const(1),
			I32Add,
			LocalSet(2),
			LocalGet(2),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			Call(allocator),
			LocalSet(3),
			LocalGet(3),
			I32Const(WasmModuleSupport.typeId(Bytes)),
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
			Call(bytesDataPointer),
			LocalGet(1),
			MemoryCopy,
			LocalGet(3),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			LocalGet(1),
			I32Add,
			I32Const(0),
			I32Store8(0),
			LocalGet(3),
			Return
		]);
		return module.addFunction(builder);
	}

	static function addStructGetPointer(module:WasmModule, name:String, bytesDataPointer:Int):Int {
		return module.addFunction(WasmFunctionBuilder.fromRaw(name, {parameters: [I32, I32, I32], results: [I32]}, [],
			[LocalGet(0), Call(bytesDataPointer), LocalGet(1), I32Add, I32Load(0), Return]));
	}

	static function addStructSetPointer(module:WasmModule, name:String, bytesDataPointer:Int):Int {
		return module.addFunction(WasmFunctionBuilder.fromRaw(name, {parameters: [I32, I32, I32, I32], results: []}, [], [
			LocalGet(0),
			Call(bytesDataPointer),
			LocalGet(1),
			I32Add,
			LocalGet(2),
			I32Store(0),
			Return
		]));
	}

	static function addStructSetUtf8(module:WasmModule, name:String, allocator:Int, bytesDataPointer:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32, I32, I32], results: []}),
			bytes = builder.parameter("bytes", 0),
			offset = builder.parameter("offset", 1),
			input = builder.parameter("input", 2),
			nullable = builder.parameter("nullable", 3),
			roots = builder.local("roots", I32),
			rootIndex = builder.local("rootIndex", I32),
			length = builder.local("length", I32),
			copy = builder.local("copy", I32);
		builder.localGet(bytes);
		builder.emit(I32Load(WasmLayout.BYTES_VIEW_ROOTS_OFFSET));
		builder.localSet(roots);
		builder.localGet(offset);
		builder.i32Const(2);
		builder.emit(I32ShrU);
		builder.i32Const(1);
		builder.i32Add();
		builder.localSet(rootIndex);
		builder.localGet(rootIndex);
		builder.localGet(roots);
		builder.emit(I32Load(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.emit(I32LtS);
		builder.i32Eqz();
		builder.if_(function(builder) builder.emit(Unreachable));
		builder.localGet(input);
		builder.i32Eqz();
		builder.ifElse(function(builder) {
			builder.localGet(nullable);
			builder.i32Eqz();
			builder.if_(function(builder) builder.emit(Unreachable));
			builder.localGet(roots);
			builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
			builder.localGet(rootIndex);
			builder.i32Const(4);
			builder.emit(I32Mul);
			builder.i32Add();
			builder.i32Const(0);
			builder.emit(I32Store(0));
			builder.localGet(bytes);
			builder.call(builder.functionRef(bytesDataPointer));
			builder.localGet(offset);
			builder.i32Add();
			builder.i32Const(0);
			builder.emit(I32Store(0));
		}, function(builder) {
			builder.localGet(input);
			builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
			builder.localSet(length);
			builder.localGet(length);
			builder.i32Const(WasmLayout.STRING_DATA_OFFSET + 1);
			builder.i32Add();
			builder.call(builder.functionRef(allocator));
			builder.localSet(copy);
			builder.localGet(copy);
			builder.i32Const(WasmModuleSupport.typeId(Bytes));
			builder.emit(I32Store(0));
			builder.localGet(copy);
			builder.localGet(length);
			builder.i32Const(1);
			builder.i32Add();
			builder.emit(I32Store(WasmLayout.STRING_LENGTH_OFFSET));
			builder.localGet(copy);
			builder.localGet(length);
			builder.i32Const(1);
			builder.i32Add();
			builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
			builder.localGet(copy);
			builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
			builder.i32Add();
			builder.localGet(input);
			builder.call(builder.functionRef(bytesDataPointer));
			builder.localGet(length);
			builder.emit(MemoryCopy);
			builder.localGet(copy);
			builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
			builder.i32Add();
			builder.localGet(length);
			builder.i32Add();
			builder.i32Const(0);
			builder.emit(I32Store8(0));
			builder.localGet(roots);
			builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
			builder.localGet(rootIndex);
			builder.i32Const(4);
			builder.emit(I32Mul);
			builder.i32Add();
			builder.localGet(copy);
			builder.emit(I32Store(0));
			builder.localGet(bytes);
			builder.call(builder.functionRef(bytesDataPointer));
			builder.localGet(offset);
			builder.i32Add();
			builder.localGet(copy);
			builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
			builder.i32Add();
			builder.emit(I32Store(0));
		});
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addStructGetUtf8(module:WasmModule, name:String, allocator:Int, bytesDataPointer:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32, I32], results: [I32]}),
			value = builder.parameter("value", 0),
			offset = builder.parameter("offset", 1),
			result = builder.parameter("result", 2),
			pointer = builder.local("pointer", I32),
			index = builder.local("index", I32),
			_unused = builder.local("unused", I32);
		builder.localGet(value);
		builder.call(builder.functionRef(bytesDataPointer));
		builder.localGet(offset);
		builder.i32Add();
		builder.emit(I32Load(0));
		builder.localSet(pointer);
		builder.localGet(pointer);
		builder.i32Eqz();
		builder.ifElse(function(builder) {
			builder.i32Const(0);
			builder.localSet(result);
		}, function(builder) {
			builder.i32Const(0);
			builder.localSet(index);
			builder.block(function(builder) {
				builder.loop(function(builder) {
					builder.localGet(pointer);
					builder.localGet(index);
					builder.i32Add();
					builder.emit(I32Load8U(0));
					builder.i32Eqz();
					builder.if_(function(builder) builder.emit(Br(1)));
					builder.localGet(index);
					builder.i32Const(1);
					builder.i32Add();
					builder.localSet(index);
					builder.emit(Br(0));
				});
			});
			builder.localGet(index);
			builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
			builder.i32Add();
			builder.call(builder.functionRef(allocator));
			builder.localSet(result);
			builder.localGet(result);
			builder.i32Const(WasmModuleSupport.typeId(Bytes));
			builder.emit(I32Store(0));
			builder.localGet(result);
			builder.localGet(index);
			builder.emit(I32Store(WasmLayout.STRING_LENGTH_OFFSET));
			builder.localGet(result);
			builder.localGet(index);
			builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
			builder.localGet(result);
			builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
			builder.i32Add();
			builder.localGet(pointer);
			builder.localGet(index);
			builder.emit(MemoryCopy);
		});
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addStructCopyPointer(module:WasmModule, name:String, allocator:Int, bytesDataPointer:Int):Int {
		return module.addFunction(WasmFunctionBuilder.fromRaw(name, {parameters: [I32, I32, I32, I32], results: [I32]},
			[{type: I32}, {type: I32}, {type: I32}], [
				LocalGet(0),
				Call(bytesDataPointer),
				LocalGet(1),
				I32Add,
				I32Load(0),
				LocalSet(4),
				LocalGet(0),
				Call(bytesDataPointer),
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
				I32Const(WasmModuleSupport.typeId(Bytes)),
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
			"_i64")) I64; else if (StringTools.endsWith(mapName,
			"_bool")) Bool; else if (StringTools.endsWith(mapName,
			"_f64")) F64; else if (StringTools.endsWith(mapName,
			"_bytes")) Bytes; else if (StringTools.endsWith(mapName, "_ref")) Dyn; else throw 'Unknown Wasm map value ABI "$mapName"';

	public static function mapEntrySize(valueType:IrType):Int
		return valueType == F64 || valueType == I64 ? 16 : 8;

	public static function mapValueOffset(valueType:IrType):Int
		return valueType == F64 || valueType == I64 ? 8 : 4;

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
		var suffix = valueType == F64 ? "f64" : valueType == I64 ? "i64" : "i32",
			name = "__array_alloc_" + suffix,
			result = functions.get(name);
		if (result == null) {
			result = WasmLinearArrays.addArrayAllocator(module, name, valueType == F64 || valueType == I64 ? 8 : 4, allocator);
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
		return module.addFunction(WasmFunctionBuilder.fromRaw(name, {parameters: [], results: [I32]}, [{type: I32}, {type: I32}], [
			I32Const(WasmLayout.MAP_HEADER_SIZE),
			Call(allocator),
			LocalTee(0),
			I32Const(WasmModuleSupport.typeId(Abstract(mapName))),
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
		return type == F64 ? F64Load(offset) : type == I64 ? I64Load(offset) : I32Load(offset);

	static function storeMapValue(type:IrType, offset:Int):WasmInstruction
		return type == F64 ? F64Store(offset) : type == I64 ? I64Store(offset) : I32Store(offset);

	static function addMapFind(module:WasmModule, name:String, keyType:IrType, valueType:IrType, stringEqual:Int):Int {
		var entrySize = mapEntrySize(valueType),
			builder = new WasmFunctionBuilder(name, {parameters: [I32, WasmModuleSupport.requireValueType(keyType)], results: [I32]}),
			map = builder.parameter("map", 0),
			key = builder.parameter("key", 1),
			index = builder.local("index", I32),
			entries = builder.local("entries", I32);
		builder.i32Const(0);
		builder.localSet(index);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(index);
				builder.localGet(map);
				builder.emit(I32Load(WasmLayout.MAP_COUNT_OFFSET));
				builder.emit(I32LtS);
				builder.ifElse(function(builder) {
					builder.localGet(map);
					builder.emit(I32Load(WasmLayout.MAP_ENTRIES_OFFSET));
					builder.localSet(entries);
					builder.localGet(entries);
					builder.localGet(index);
					builder.i32Const(entrySize);
					builder.emit(I32Mul);
					builder.i32Add();
					builder.emit(I32Load(0));
					builder.localGet(key);
					if (keyType == Bytes)
						builder.call(builder.functionRef(stringEqual));
					else
						builder.emit(I32Eq);
					builder.if_(function(builder) {
						builder.localGet(index);
						builder.return_();
					});
					builder.localGet(index);
					builder.i32Const(1);
					builder.i32Add();
					builder.localSet(index);
					builder.emit(Br(1));
				}, function(builder) builder.emit(Br(2)));
			});
		});
		builder.i32Const(-1);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addMapSet(module:WasmModule, name:String, keyType:IrType, valueType:IrType, entrySize:Int, valueOffset:Int, allocator:Int,
			stringEqual:Int):Int {
		var type:WasmFunctionType = {
			parameters: [
				I32,
				WasmModuleSupport.requireValueType(keyType),
				WasmModuleSupport.requireValueType(valueType)
			],
			results: []
		};
		var builder = new WasmFunctionBuilder(name, type),
			map = builder.parameter("map", 0),
			key = builder.parameter("key", 1),
			value = builder.parameter("value", 2),
			index = builder.local("index", I32),
			entries = builder.local("entries", I32),
			count = builder.local("count", I32),
			capacity = builder.local("capacity", I32),
			newCapacity = builder.local("newCapacity", I32),
			newEntries = builder.local("newEntries", I32);
		builder.i32Const(0);
		builder.localSet(index);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(index);
				builder.localGet(map);
				builder.emit(I32Load(WasmLayout.MAP_COUNT_OFFSET));
				builder.emit(I32LtS);
				builder.ifElse(function(builder) {
					builder.localGet(map);
					builder.emit(I32Load(WasmLayout.MAP_ENTRIES_OFFSET));
					builder.localSet(entries);
					builder.localGet(entries);
					builder.localGet(index);
					builder.i32Const(entrySize);
					builder.emit(I32Mul);
					builder.i32Add();
					builder.emit(I32Load(0));
					builder.localGet(key);
					if (keyType == Bytes)
						builder.call(builder.functionRef(stringEqual));
					else
						builder.emit(I32Eq);
					builder.if_(function(builder) {
						builder.localGet(entries);
						builder.localGet(index);
						builder.i32Const(entrySize);
						builder.emit(I32Mul);
						builder.i32Add();
						builder.localGet(key);
						builder.emit(I32Store(0));
						builder.localGet(entries);
						builder.localGet(index);
						builder.i32Const(entrySize);
						builder.emit(I32Mul);
						builder.i32Add();
						builder.localGet(value);
						builder.emit(storeMapValue(valueType, valueOffset));
						builder.return_();
					});
					builder.localGet(index);
					builder.i32Const(1);
					builder.i32Add();
					builder.localSet(index);
					builder.emit(Br(1));
				}, function(builder) builder.emit(Br(2)));
			});
		});
		builder.localGet(map);
		builder.emit(I32Load(WasmLayout.MAP_COUNT_OFFSET));
		builder.localSet(count);
		builder.localGet(map);
		builder.emit(I32Load(WasmLayout.MAP_CAPACITY_OFFSET));
		builder.localSet(capacity);
		builder.localGet(count);
		builder.localGet(capacity);
		builder.emit(I32Eq);
		builder.if_(function(builder) {
			builder.localGet(capacity);
			builder.i32Const(2);
			builder.emit(I32Mul);
			builder.localSet(newCapacity);
			builder.localGet(newCapacity);
			builder.i32Const(entrySize);
			builder.emit(I32Mul);
			builder.call(builder.functionRef(allocator));
			builder.localSet(newEntries);
			builder.localGet(newEntries);
			builder.localGet(map);
			builder.emit(I32Load(WasmLayout.MAP_ENTRIES_OFFSET));
			builder.localGet(count);
			builder.i32Const(entrySize);
			builder.emit(I32Mul);
			builder.emit(MemoryCopy);
			builder.localGet(newEntries);
			builder.i32Const(WasmLayout.GC_BLOCK_HEADER_SIZE);
			builder.i32Sub();
			builder.i32Const(WasmLayout.GC_BLOCK_LINK_OFFSET);
			builder.i32Add();
			builder.localGet(map);
			builder.emit(I32Store(0));
			builder.localGet(map);
			builder.localGet(newEntries);
			builder.emit(I32Store(WasmLayout.MAP_ENTRIES_OFFSET));
			builder.localGet(map);
			builder.localGet(newCapacity);
			builder.emit(I32Store(WasmLayout.MAP_CAPACITY_OFFSET));
		});
		builder.localGet(map);
		builder.emit(I32Load(WasmLayout.MAP_ENTRIES_OFFSET));
		builder.localSet(entries);
		builder.localGet(entries);
		builder.localGet(count);
		builder.i32Const(entrySize);
		builder.emit(I32Mul);
		builder.i32Add();
		builder.localGet(key);
		builder.emit(I32Store(0));
		builder.localGet(entries);
		builder.localGet(count);
		builder.i32Const(entrySize);
		builder.emit(I32Mul);
		builder.i32Add();
		builder.localGet(value);
		builder.emit(storeMapValue(valueType, valueOffset));
		builder.localGet(map);
		builder.localGet(count);
		builder.i32Const(1);
		builder.i32Add();
		builder.emit(I32Store(WasmLayout.MAP_COUNT_OFFSET));
		return module.addFunction(builder.finish());
	}

	static function addMapExists(module:WasmModule, name:String, keyType:IrType, valueType:IrType, stringEqual:Int, find:Int):Int
		return module.addFunction(WasmFunctionBuilder.fromRaw(name, {parameters: [I32, WasmModuleSupport.requireValueType(keyType)], results: [I32]}, [],
			[LocalGet(0), LocalGet(1), Call(find), I32Const(-1), I32Eq, I32Eqz, Return]));

	static function addMapGet(module:WasmModule, name:String, keyType:IrType, valueType:IrType, entrySize:Int, valueOffset:Int, allocator:Int,
			stringEqual:Int, find:Int):Int {
		var type:WasmFunctionType = {parameters: [I32, WasmModuleSupport.requireValueType(keyType)], results: [I32]},
			builder = new WasmFunctionBuilder(name, type),
			map = builder.parameter("map", 0),
			key = builder.parameter("key", 1),
			index = builder.local("index", I32),
			entries = builder.local("entries", I32),
			result = builder.local("result", I32);
		builder.localGet(map);
		builder.localGet(key);
		builder.call(builder.functionRef(find));
		builder.localSet(index);
		builder.localGet(index);
		builder.i32Const(-1);
		builder.emit(I32Eq);
		builder.ifElse(function(builder) {
			builder.i32Const(0);
			builder.localSet(result);
		}, function(builder) {
			builder.localGet(map);
			builder.emit(I32Load(WasmLayout.MAP_ENTRIES_OFFSET));
			builder.localSet(entries);
			if (valueType == I32 || valueType == Bool) {
				builder.i32Const(WasmLayout.DYN_I32_SIZE);
				builder.call(builder.functionRef(allocator));
				builder.localSet(result);
				builder.localGet(result);
				builder.i32Const(WasmModuleSupport.typeId(valueType));
				builder.emit(I32Store(0));
				builder.localGet(result);
				builder.localGet(entries);
				builder.localGet(index);
				builder.i32Const(entrySize);
				builder.emit(I32Mul);
				builder.i32Add();
				builder.emit(I32Load(valueOffset));
				builder.emit(I32Store(WasmLayout.DYN_PAYLOAD_OFFSET));
			} else if (valueType == F64) {
				builder.i32Const(WasmLayout.DYN_F64_SIZE);
				builder.call(builder.functionRef(allocator));
				builder.localSet(result);
				builder.localGet(result);
				builder.i32Const(WasmModuleSupport.typeId(F64));
				builder.emit(I32Store(0));
				builder.localGet(result);
				builder.localGet(entries);
				builder.localGet(index);
				builder.i32Const(entrySize);
				builder.emit(I32Mul);
				builder.i32Add();
				builder.emit(F64Load(valueOffset));
				builder.emit(F64Store(WasmLayout.DYN_PAYLOAD_OFFSET));
			} else if (valueType == I64) {
				builder.i32Const(WasmLayout.DYN_I64_SIZE);
				builder.call(builder.functionRef(allocator));
				builder.localSet(result);
				builder.localGet(result);
				builder.i32Const(WasmModuleSupport.typeId(I64));
				builder.emit(I32Store(0));
				builder.localGet(result);
				builder.localGet(entries);
				builder.localGet(index);
				builder.i32Const(entrySize);
				builder.emit(I32Mul);
				builder.i32Add();
				builder.emit(I64Load(valueOffset));
				builder.emit(I64Store(WasmLayout.DYN_PAYLOAD_OFFSET));
			} else {
				builder.localGet(entries);
				builder.localGet(index);
				builder.i32Const(entrySize);
				builder.emit(I32Mul);
				builder.i32Add();
				builder.emit(loadMapValue(valueType, valueOffset));
				builder.localSet(result);
			}
		});
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addMapProjection(module:WasmModule, name:String, elementType:IrType, entrySize:Int, valueOffset:Int, allocator:Int,
			arrayAllocator:Int):Int {
		var stride = WasmLayout.arrayStride(elementType),
			builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [I32]}),
			map = builder.parameter("map", 0),
			array = builder.local("array", I32),
			entries = builder.local("entries", I32),
			index = builder.local("index", I32);
		builder.localGet(map);
		builder.emit(I32Load(WasmLayout.MAP_COUNT_OFFSET));
		builder.call(builder.functionRef(arrayAllocator));
		builder.localSet(array);
		builder.localGet(map);
		builder.emit(I32Load(WasmLayout.MAP_ENTRIES_OFFSET));
		builder.localSet(entries);
		builder.i32Const(0);
		builder.localSet(index);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(index);
				builder.localGet(map);
				builder.emit(I32Load(WasmLayout.MAP_COUNT_OFFSET));
				builder.emit(I32LtS);
				builder.ifElse(function(builder) {
					builder.localGet(array);
					builder.emit(I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET));
					builder.localGet(index);
					builder.i32Const(stride);
					builder.emit(I32Mul);
					builder.i32Add();
					builder.localGet(entries);
					builder.localGet(index);
					builder.i32Const(entrySize);
					builder.emit(I32Mul);
					builder.i32Add();
					builder.emit(loadMapValue(elementType, valueOffset));
					builder.emit(storeMapValue(elementType, 0));
					builder.localGet(index);
					builder.i32Const(1);
					builder.i32Add();
					builder.localSet(index);
					builder.emit(Br(1));
				}, function(builder) builder.emit(Br(2)));
			});
		});
		builder.localGet(array);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addMapRemove(module:WasmModule, name:String, keyType:IrType, valueType:IrType, entrySize:Int, stringEqual:Int, find:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, WasmModuleSupport.requireValueType(keyType)], results: [I32]}),
			map = builder.parameter("map", 0),
			key = builder.parameter("key", 1),
			index = builder.local("index", I32),
			entries = builder.local("entries", I32),
			count = builder.local("count", I32),
			tailCount = builder.local("tailCount", I32);
		builder.localGet(map);
		builder.localGet(key);
		builder.call(builder.functionRef(find));
		builder.localTee(index);
		builder.i32Const(-1);
		builder.emit(I32Eq);
		builder.ifElse(function(builder) {
			builder.i32Const(0);
		}, function(builder) {
			builder.localGet(map);
			builder.emit(I32Load(WasmLayout.MAP_ENTRIES_OFFSET));
			builder.localSet(entries);
			builder.localGet(map);
			builder.emit(I32Load(WasmLayout.MAP_COUNT_OFFSET));
			builder.localSet(count);
			builder.localGet(count);
			builder.localGet(index);
			builder.i32Sub();
			builder.i32Const(1);
			builder.i32Sub();
			builder.localSet(tailCount);
			builder.i32Const(0);
			builder.localGet(tailCount);
			builder.emit(I32LtS);
			builder.if_(function(builder) {
				builder.localGet(entries);
				builder.localGet(index);
				builder.i32Const(entrySize);
				builder.emit(I32Mul);
				builder.i32Add();
				builder.localGet(entries);
				builder.localGet(index);
				builder.i32Const(1);
				builder.i32Add();
				builder.i32Const(entrySize);
				builder.emit(I32Mul);
				builder.i32Add();
				builder.localGet(tailCount);
				builder.i32Const(entrySize);
				builder.emit(I32Mul);
				builder.emit(MemoryCopy);
			});
			builder.localGet(map);
			builder.localGet(count);
			builder.i32Const(1);
			builder.i32Sub();
			builder.emit(I32Store(WasmLayout.MAP_COUNT_OFFSET));
			builder.i32Const(1);
		}, I32);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addMapClear(module:WasmModule, name:String):Int
		return module.addFunction(WasmFunctionBuilder.fromRaw(name, {parameters: [I32], results: []}, [],
			[LocalGet(0), I32Const(0), I32Store(WasmLayout.MAP_COUNT_OFFSET)]));

	static function addMapSize(module:WasmModule, name:String):Int
		return module.addFunction(WasmFunctionBuilder.fromRaw(name, {parameters: [I32], results: [I32]}, [],
			[LocalGet(0), I32Load(WasmLayout.MAP_COUNT_OFFSET), Return]));

	static function addDynamicInt(module:WasmModule, name:String):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [I32]}),
			value = builder.parameter("value", 0),
			dynamicTypes:Array<IrType> = [I32, Bool];
		builder.localGet(value);
		builder.i32Eqz();
		builder.if_(function(builder) {
			builder.i32Const(0);
			builder.return_();
		});
		for (type in dynamicTypes) {
			builder.localGet(value);
			builder.emit(I32Load(0));
			builder.i32Const(WasmModuleSupport.typeId(type));
			builder.emit(I32Eq);
			builder.if_(function(builder) {
				builder.localGet(value);
				builder.emit(I32Load(WasmLayout.DYN_PAYLOAD_OFFSET));
				builder.return_();
			});
		}
		builder.localGet(value);
		builder.emit(I32Load(0));
		builder.i32Const(WasmModuleSupport.typeId(F64));
		builder.emit(I32Eq);
		builder.if_(function(builder) {
			builder.localGet(value);
			builder.emit(F64Load(WasmLayout.DYN_PAYLOAD_OFFSET));
			builder.emit(I32TruncF64S);
			builder.return_();
		});
		builder.localGet(value);
		builder.emit(I32Load(0));
		builder.i32Const(WasmModuleSupport.typeId(I64));
		builder.emit(I32Eq);
		builder.if_(function(builder) {
			builder.localGet(value);
			builder.emit(I64Load(WasmLayout.DYN_PAYLOAD_OFFSET));
			builder.emit(I32WrapI64);
			builder.return_();
		});
		builder.emit(Unreachable);
		return module.addFunction(builder.finish());
	}

	static function addDynamicIsObject(module:WasmModule, name:String, program:IrProgram):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [I32]}),
			value = builder.parameter("value", 0);
		for (object in program.objects) {
			builder.localGet(value);
			builder.i32Const(WasmModuleSupport.typeId(Obj(object.name)));
			builder.emit(I32Eq);
			builder.if_(function(builder) {
				builder.i32Const(1);
				builder.return_();
			});
		}
		for (enumDecl in program.enums) {
			builder.localGet(value);
			builder.i32Const(WasmModuleSupport.typeId(Enum(enumDecl.name)));
			builder.emit(I32Eq);
			builder.if_(function(builder) {
				builder.i32Const(1);
				builder.return_();
			});
		}
		builder.localGet(value);
		builder.i32Const(1);
		builder.emit(I32And);
		builder.if_(function(builder) {
			builder.i32Const(0);
			builder.return_();
		});
		builder.localGet(value);
		builder.i32Eqz();
		builder.if_(function(builder) {
			builder.i32Const(0);
			builder.return_();
		});
		for (typeId in [
			WasmLayout.CLOSURE_TYPE_ID,
			WasmModuleSupport.typeId(I32),
			WasmModuleSupport.typeId(Bool),
			WasmModuleSupport.typeId(I64),
			WasmModuleSupport.typeId(F64),
			WasmModuleSupport.typeId(Bytes)
		]) {
			builder.localGet(value);
			builder.emit(I32Load(0));
			builder.i32Const(typeId);
			builder.emit(I32Eq);
			builder.if_(function(builder) {
				builder.i32Const(0);
				builder.return_();
			});
		}
		builder.i32Const(1);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addTypeTest(module:WasmModule, name:String, program:IrProgram):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: [I32]}),
			value = builder.parameter("value", 0),
			typeId = builder.parameter("typeId", 1),
			result = builder.local("result", I32);
		builder.localGet(value);
		builder.i32Eqz();
		builder.ifElse(function(builder) {
			builder.i32Const(0);
			builder.localSet(result);
		}, function(builder) {
			builder.localGet(value);
			builder.emit(I32Load(0));
			builder.localGet(typeId);
			builder.emit(I32Eq);
			builder.localSet(result);
			for (object in program.objects) {
				var accepted = [WasmModuleSupport.typeId(Obj(object.name))];
				var base = object.base;
				while (base != null) {
					accepted.push(WasmModuleSupport.typeId(Obj(base)));
					var next:Null<String> = null;
					for (candidate in program.objects)
						if (candidate.name == base)
							next = candidate.base;
					base = next;
				}
				for (interfaceName in object.interfaces)
					accepted.push(WasmModuleSupport.typeId(Virtual(interfaceName)));
				builder.localGet(value);
				builder.emit(I32Load(0));
				builder.i32Const(WasmModuleSupport.typeId(Obj(object.name)));
				builder.emit(I32Eq);
				builder.if_(function(builder) {
					for (index in 0...accepted.length) {
						builder.localGet(typeId);
						builder.i32Const(accepted[index]);
						builder.emit(I32Eq);
						if (index > 0)
							builder.emit(I32Or);
					}
					builder.localSet(result);
				});
			}
		});
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addStringCharCodeAt(module:WasmModule, name:String):Int {
		return module.addFunction(WasmFunctionBuilder.fromRaw(name, {parameters: [I32, I32], results: [I32]}, [{type: I32}], [
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
		return module.addFunction(WasmFunctionBuilder.fromRaw(name, {parameters: [I32, I32], results: [I32]}, [{type: I32}, {type: I32}, {type: I32}], [
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
			I32Const(WasmModuleSupport.typeId(Bytes)),
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

	/** Copy a linear-memory UTF-8 byte string while folding ASCII letters. */
	static function addStringCase(module:WasmModule, name:String, allocator:Int, lowercase:Bool):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [I32]}),
			source = builder.parameter("source", 0),
			length = builder.local("length", I32),
			result = builder.local("result", I32),
			index = builder.local("index", I32),
			byte = builder.local("byte", I32);
		builder.localGet(source);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localSet(length);
		builder.localGet(length);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.call(builder.functionRef(allocator));
		builder.localSet(result);
		builder.localGet(result);
		builder.i32Const(WasmModuleSupport.typeId(Bytes));
		builder.emit(I32Store(0));
		builder.localGet(result);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localGet(result);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.localGet(result);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.localGet(source);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.localGet(length);
		builder.emit(MemoryCopy);
		builder.i32Const(0);
		builder.localSet(index);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(index);
				builder.localGet(length);
				builder.emit(I32LtS);
				builder.i32Eqz();
				builder.emit(BrIf(1));
				builder.localGet(result);
				builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
				builder.i32Add();
				builder.localGet(index);
				builder.i32Add();
				builder.emit(I32Load8U(0));
				builder.localSet(byte);
				builder.localGet(byte);
				builder.i32Const(lowercase ? 65 : 97);
				builder.emit(I32LtS);
				builder.i32Eqz();
				builder.localGet(byte);
				builder.i32Const(lowercase ? 90 : 122);
				builder.emit(I32LeS);
				builder.emit(I32And);
				builder.if_(function(builder) {
					builder.localGet(result);
					builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
					builder.i32Add();
					builder.localGet(index);
					builder.i32Add();
					builder.localGet(byte);
					builder.i32Const(lowercase ? 32 : -32);
					builder.i32Add();
					builder.emit(I32Store8(0));
				});
				builder.localGet(index);
				builder.i32Const(1);
				builder.i32Add();
				builder.localSet(index);
				builder.emit(Br(0));
			});
		});
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addStringIndexOf(module:WasmModule, name:String):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: [I32]}),
			value = builder.parameter("value", 0),
			needle = builder.parameter("needle", 1),
			valueLength = builder.local("valueLength", I32),
			needleLength = builder.local("needleLength", I32),
			index = builder.local("index", I32),
			inner = builder.local("inner", I32),
			result = builder.local("result", I32);
		builder.localGet(value);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localSet(valueLength);
		builder.localGet(needle);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localSet(needleLength);
		builder.i32Const(-1);
		builder.localSet(result);
		builder.localGet(needleLength);
		builder.i32Eqz();
		builder.if_(function(builder) {
			builder.i32Const(0);
			builder.localSet(result);
		});
		builder.i32Const(0);
		builder.localSet(index);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(index);
				builder.localGet(needleLength);
				builder.i32Add();
				builder.localGet(valueLength);
				builder.emit(I32LtS);
				builder.i32Eqz();
				builder.emit(BrIf(1));
				builder.i32Const(0);
				builder.localSet(inner);
				builder.block(function(builder) {
					builder.loop(function(builder) {
						builder.localGet(inner);
						builder.localGet(needleLength);
						builder.emit(I32Eq);
						builder.emit(BrIf(1));
						builder.localGet(value);
						builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
						builder.i32Add();
						builder.localGet(index);
						builder.i32Add();
						builder.localGet(inner);
						builder.i32Add();
						builder.emit(I32Load8U(0));
						builder.localGet(needle);
						builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
						builder.i32Add();
						builder.localGet(inner);
						builder.i32Add();
						builder.emit(I32Load8U(0));
						builder.emit(I32Eq);
						builder.i32Eqz();
						builder.emit(BrIf(1));
						builder.localGet(inner);
						builder.i32Const(1);
						builder.i32Add();
						builder.localSet(inner);
						builder.emit(Br(0));
					});
				});
				builder.localGet(inner);
				builder.localGet(needleLength);
				builder.emit(I32Eq);
				builder.if_(function(builder) {
					builder.localGet(index);
					builder.localSet(result);
					builder.emit(Br(2));
				});
				builder.localGet(index);
				builder.i32Const(1);
				builder.i32Add();
				builder.localSet(index);
				builder.emit(Br(0));
			});
		});
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addStringSubstring(module:WasmModule, name:String, allocator:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32, I32], results: [I32]}),
			source = builder.parameter("source", 0),
			startArg = builder.parameter("start", 1),
			endArg = builder.parameter("end", 2),
			length = builder.local("length", I32),
			start = builder.local("startValue", I32),
			end = builder.local("endValue", I32),
			result = builder.local("result", I32);
		builder.localGet(source);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localSet(length);
		builder.localGet(startArg);
		builder.i32Const(0);
		builder.emit(I32LtS);
		builder.ifElse(function(builder) builder.i32Const(0), function(builder) builder.localGet(startArg), I32);
		builder.localSet(start);
		builder.localGet(endArg);
		builder.localGet(start);
		builder.emit(I32LtS);
		builder.ifElse(function(builder) builder.localGet(start), function(builder) builder.localGet(endArg), I32);
		builder.localSet(end);
		builder.localGet(start);
		builder.localGet(length);
		builder.emit(I32LtS);
		builder.ifElse(function(builder) builder.localGet(start), function(builder) builder.localGet(length), I32);
		builder.localSet(start);
		builder.localGet(end);
		builder.localGet(length);
		builder.emit(I32LtS);
		builder.ifElse(function(builder) builder.localGet(end), function(builder) builder.localGet(length), I32);
		builder.localSet(end);
		builder.localGet(end);
		builder.localGet(start);
		builder.emit(I32LtS);
		builder.ifElse(function(builder) builder.localGet(start), function(builder) builder.localGet(end), I32);
		builder.localSet(end);
		builder.localGet(end);
		builder.localGet(start);
		builder.emit(I32Sub);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.call(builder.functionRef(allocator));
		builder.localSet(result);
		builder.localGet(result);
		builder.i32Const(WasmModuleSupport.typeId(Bytes));
		builder.emit(I32Store(0));
		builder.localGet(result);
		builder.localGet(end);
		builder.localGet(start);
		builder.emit(I32Sub);
		builder.emit(I32Store(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localGet(result);
		builder.localGet(end);
		builder.localGet(start);
		builder.emit(I32Sub);
		builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.localGet(result);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.localGet(source);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.localGet(start);
		builder.i32Add();
		builder.localGet(end);
		builder.localGet(start);
		builder.emit(I32Sub);
		builder.emit(MemoryCopy);
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addStringSplit(module:WasmModule, name:String, allocator:Int, substring:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: [I32]}),
			source = builder.parameter("source", 0),
			separator = builder.parameter("separator", 1),
			sourceLength = builder.local("sourceLength", I32),
			separatorLength = builder.local("separatorLength", I32),
			result = builder.local("result", I32),
			data = builder.local("data", I32),
			capacity = builder.local("capacity", I32),
			count = builder.local("count", I32),
			scan = builder.local("scan", I32),
			start = builder.local("start", I32),
			separatorIndex = builder.local("separatorIndex", I32),
			step = builder.local("step", I32),
			firstByte = builder.local("firstByte", I32),
			part = builder.local("part", I32);

		builder.localGet(source);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localSet(sourceLength);
		builder.localGet(separator);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localSet(separatorLength);

		// At most sourceLength + 1 parts can be produced. Allocate the backing
		// storage once so split does not depend on the array push runtime helper.
		builder.i32Const(WasmLayout.ARRAY_HEADER_SIZE);
		builder.call(builder.functionRef(allocator));
		builder.localSet(result);
		builder.localGet(result);
		builder.i32Const(WasmModuleSupport.typeId(Array(Dyn)));
		builder.emit(I32Store(0));
		builder.localGet(result);
		builder.i32Const(0);
		builder.emit(I32Store(WasmLayout.ARRAY_LENGTH_OFFSET));
		builder.localGet(result);
		builder.localGet(sourceLength);
		builder.i32Const(1);
		builder.i32Add();
		builder.localTee(capacity);
		builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.localGet(capacity);
		builder.i32Const(4);
		builder.emit(I32Mul);
		builder.call(builder.functionRef(allocator));
		builder.localSet(data);
		WasmLinearGc.appendGcContainerOwner(builder.body, data, result);
		builder.localGet(result);
		builder.localGet(data);
		builder.emit(I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET));

		builder.i32Const(0);
		builder.localSet(count);
		builder.i32Const(0);
		builder.localSet(scan);
		builder.i32Const(0);
		builder.localSet(start);
		builder.localGet(separatorLength);
		builder.i32Eqz();
		builder.ifElse(function(builder) {
			// Haxe splits an empty separator at UTF-8 code-point boundaries.
			builder.block(function(builder) {
				builder.loop(function(builder) {
					builder.localGet(scan);
					builder.localGet(sourceLength);
					builder.emit(I32LtS);
					builder.i32Eqz();
					builder.emit(BrIf(1));
					builder.localGet(source);
					builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
					builder.i32Add();
					builder.localGet(scan);
					builder.i32Add();
					builder.emit(I32Load8U(0));
					builder.localSet(firstByte);
					builder.localGet(firstByte);
					builder.i32Const(240);
					builder.emit(I32LtS);
					builder.i32Eqz();
					builder.ifElse(function(builder) {
						builder.i32Const(4);
						builder.localSet(step);
					}, function(builder) {
						builder.localGet(firstByte);
						builder.i32Const(224);
						builder.emit(I32LtS);
						builder.i32Eqz();
						builder.ifElse(function(builder) {
							builder.i32Const(3);
							builder.localSet(step);
						}, function(builder) {
							builder.localGet(firstByte);
							builder.i32Const(192);
							builder.emit(I32LtS);
							builder.i32Eqz();
							builder.ifElse(function(builder) {
								builder.i32Const(2);
								builder.localSet(step);
							}, function(builder) {
								builder.i32Const(1);
								builder.localSet(step);
							});
						});
					});
					builder.localGet(scan);
					builder.localSet(start);
					builder.localGet(scan);
					builder.localGet(step);
					builder.i32Add();
					builder.localSet(scan);
					appendLinearSplitPart(builder, source, result, data, count, start, scan, part, substring);
					builder.emit(Br(0));
				});
			});
		}, function(builder) {
			builder.block(function(builder) {
				builder.loop(function(builder) {
					builder.localGet(scan);
					builder.localGet(separatorLength);
					builder.i32Add();
					builder.localGet(sourceLength);
					builder.emit(I32LeS);
					builder.i32Eqz();
					builder.emit(BrIf(1));
					builder.i32Const(0);
					builder.localSet(separatorIndex);
					builder.block(function(builder) {
						builder.loop(function(builder) {
							builder.localGet(separatorIndex);
							builder.localGet(separatorLength);
							builder.emit(I32LtS);
							builder.i32Eqz();
							builder.emit(BrIf(1));
							builder.localGet(source);
							builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
							builder.i32Add();
							builder.localGet(scan);
							builder.i32Add();
							builder.localGet(separatorIndex);
							builder.i32Add();
							builder.emit(I32Load8U(0));
							builder.localGet(separator);
							builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
							builder.i32Add();
							builder.localGet(separatorIndex);
							builder.i32Add();
							builder.emit(I32Load8U(0));
							builder.emit(I32Eq);
							builder.i32Eqz();
							builder.emit(BrIf(1));
							builder.localGet(separatorIndex);
							builder.i32Const(1);
							builder.i32Add();
							builder.localSet(separatorIndex);
							builder.emit(Br(0));
						});
					});
					builder.localGet(separatorIndex);
					builder.localGet(separatorLength);
					builder.emit(I32Eq);
					builder.ifElse(function(builder) {
						appendLinearSplitPart(builder, source, result, data, count, start, scan, part, substring);
						builder.localGet(scan);
						builder.localGet(separatorLength);
						builder.i32Add();
						builder.localSet(scan);
						builder.localGet(scan);
						builder.localSet(start);
					}, function(builder) {
						builder.localGet(scan);
						builder.i32Const(1);
						builder.i32Add();
						builder.localSet(scan);
					});
					builder.emit(Br(0));
				});
			});
			appendLinearSplitPart(builder, source, result, data, count, start, sourceLength, part, substring);
		});
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function appendLinearSplitPart(builder:WasmFunctionBuilder, source:WasmLocalRef, result:WasmLocalRef, data:WasmLocalRef, count:WasmLocalRef,
			start:WasmLocalRef, end:WasmLocalRef, part:WasmLocalRef, substring:Int):Void {
		builder.localGet(source);
		builder.localGet(start);
		builder.localGet(end);
		builder.call(builder.functionRef(substring));
		builder.localSet(part);
		builder.localGet(data);
		builder.localGet(count);
		builder.i32Const(4);
		builder.emit(I32Mul);
		builder.i32Add();
		builder.localGet(part);
		builder.emit(I32Store(0));
		builder.localGet(count);
		builder.i32Const(1);
		builder.i32Add();
		builder.localSet(count);
		builder.localGet(result);
		builder.localGet(count);
		builder.emit(I32Store(WasmLayout.ARRAY_LENGTH_OFFSET));
	}

	static function addStringCharAt(module:WasmModule, name:String, allocator:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: [I32]}),
			source = builder.parameter("source", 0),
			index = builder.parameter("index", 1),
			result = builder.local("result", I32),
			length = builder.local("length", I32);
		builder.localGet(source);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localSet(length);
		builder.localGet(index);
		builder.i32Const(0);
		builder.emit(I32LtS);
		builder.i32Eqz();
		builder.localGet(index);
		builder.localGet(length);
		builder.emit(I32LtS);
		builder.emit(I32And);
		builder.ifElse(function(builder) {
			builder.i32Const(1);
			builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
			builder.i32Add();
			builder.call(builder.functionRef(allocator));
			builder.localSet(result);
			builder.localGet(result);
			builder.i32Const(WasmModuleSupport.typeId(Bytes));
			builder.emit(I32Store(0));
			builder.localGet(result);
			builder.i32Const(1);
			builder.emit(I32Store(WasmLayout.STRING_LENGTH_OFFSET));
			builder.localGet(result);
			builder.i32Const(1);
			builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
			builder.localGet(result);
			builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
			builder.i32Add();
			builder.localGet(source);
			builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
			builder.i32Add();
			builder.localGet(index);
			builder.i32Add();
			builder.emit(I32Load8U(0));
			builder.emit(I32Store8(0));
		}, function(builder) {
			builder.i32Const(0);
			builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
			builder.i32Add();
			builder.call(builder.functionRef(allocator));
			builder.localSet(result);
			builder.localGet(result);
			builder.i32Const(WasmModuleSupport.typeId(Bytes));
			builder.emit(I32Store(0));
			builder.localGet(result);
			builder.i32Const(0);
			builder.emit(I32Store(WasmLayout.STRING_LENGTH_OFFSET));
			builder.localGet(result);
			builder.i32Const(0);
			builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		});
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addStringFromCharCode(module:WasmModule, name:String, allocator:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [I32]}),
			result = builder.local("result", I32);
		builder.i32Const(1);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.call(builder.functionRef(allocator));
		builder.localSet(result);
		builder.localGet(result);
		builder.i32Const(WasmModuleSupport.typeId(Bytes));
		builder.emit(I32Store(0));
		builder.localGet(result);
		builder.i32Const(1);
		builder.emit(I32Store(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localGet(result);
		builder.i32Const(1);
		builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.localGet(result);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.localGet(0);
		builder.emit(I32Store8(0));
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addIntToString(module:WasmModule, name:String, allocator:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [I32]}),
			value = builder.parameter("value", 0),
			number = builder.local("number", I32),
			digitCount = builder.local("digitCount", I32),
			isNegative = builder.local("isNegative", I32),
			result = builder.local("result", I32),
			lastIndex = builder.local("lastIndex", I32),
			digit = builder.local("digit", I32),
			character = builder.local("character", I32);
		builder.localGet(value);
		builder.localSet(number);
		builder.i32Const(0);
		builder.localSet(digitCount);
		builder.localGet(value);
		builder.i32Const(0);
		builder.emit(I32LtS);
		builder.localSet(isNegative);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(digitCount);
				builder.i32Const(1);
				builder.i32Add();
				builder.localSet(digitCount);
				builder.localGet(number);
				builder.i32Const(10);
				builder.emit(I32DivS);
				builder.localTee(number);
				builder.i32Eqz();
				builder.emit(BrIf(1));
				builder.emit(Br(0));
			});
		});
		builder.localGet(digitCount);
		builder.localGet(isNegative);
		builder.i32Add();
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.call(builder.functionRef(allocator));
		builder.localSet(result);
		builder.localGet(result);
		builder.i32Const(WasmModuleSupport.typeId(Bytes));
		builder.emit(I32Store(0));
		builder.localGet(result);
		builder.localGet(digitCount);
		builder.localGet(isNegative);
		builder.i32Add();
		builder.emit(I32Store(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localGet(result);
		builder.localGet(digitCount);
		builder.localGet(isNegative);
		builder.i32Add();
		builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.localGet(value);
		builder.localSet(number);
		builder.localGet(digitCount);
		builder.localGet(isNegative);
		builder.i32Add();
		builder.i32Const(1);
		builder.i32Sub();
		builder.localSet(lastIndex);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(digitCount);
				builder.i32Eqz();
				builder.emit(BrIf(1));
				builder.localGet(number);
				builder.i32Const(10);
				builder.emit(I32RemS);
				builder.localSet(digit);
				builder.localGet(number);
				builder.i32Const(10);
				builder.emit(I32DivS);
				builder.localSet(number);
				builder.localGet(result);
				builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
				builder.i32Add();
				builder.localGet(lastIndex);
				builder.i32Add();
				builder.localGet(isNegative);
				builder.ifElse(function(builder) {
					builder.i32Const(48);
					builder.localGet(digit);
					builder.i32Sub();
					builder.localSet(character);
				}, function(builder) {
					builder.i32Const(48);
					builder.localGet(digit);
					builder.i32Add();
					builder.localSet(character);
				});
				builder.localGet(character);
				builder.emit(I32Store8(0));
				builder.localGet(digitCount);
				builder.i32Const(1);
				builder.i32Sub();
				builder.localSet(digitCount);
				builder.localGet(lastIndex);
				builder.i32Const(1);
				builder.i32Sub();
				builder.localSet(lastIndex);
				builder.emit(Br(0));
			});
		});
		builder.localGet(isNegative);
		builder.if_(function(builder) {
			builder.localGet(result);
			builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
			builder.i32Add();
			builder.i32Const(45);
			builder.emit(I32Store8(0));
		});
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addInt64ToString(module:WasmModule, name:String, allocator:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I64], results: [I32]}),
			value = builder.parameter("value", 0),
			isNegative = builder.local("isNegative", I32),
			digitCount = builder.local("digitCount", I32),
			number = builder.local("number", I64),
			result = builder.local("result", I32),
			length = builder.local("length", I32),
			index = builder.local("index", I32),
			character = builder.local("character", I32);
		builder.localGet(value);
		builder.emit(I64Const(0));
		builder.emit(I64LtS);
		builder.localSet(isNegative);
		builder.localGet(isNegative);
		builder.ifElse(function(builder) {
			builder.localGet(value);
		}, function(builder) {
			builder.emit(I64Const(0));
			builder.localGet(value);
			builder.emit(I64Sub);
		}, I64);
		builder.localSet(number);
		builder.i32Const(1);
		builder.localSet(digitCount);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(number);
				builder.emit(I64Const(-10));
				builder.emit(I64LeS);
				builder.i32Eqz();
				builder.emit(BrIf(1));
				builder.localGet(number);
				builder.emit(I64Const(10));
				builder.emit(I64DivS);
				builder.localSet(number);
				builder.localGet(digitCount);
				builder.i32Const(1);
				builder.i32Add();
				builder.localSet(digitCount);
				builder.emit(Br(0));
			});
		});
		builder.localGet(isNegative);
		builder.ifElse(function(builder) {
			builder.localGet(value);
		}, function(builder) {
			builder.emit(I64Const(0));
			builder.localGet(value);
			builder.emit(I64Sub);
		}, I64);
		builder.localSet(number);
		builder.localGet(digitCount);
		builder.localGet(isNegative);
		builder.i32Add();
		builder.localTee(length);
		builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
		builder.i32Add();
		builder.call(builder.functionRef(allocator));
		builder.localSet(result);
		builder.localGet(result);
		builder.i32Const(WasmModuleSupport.typeId(Bytes));
		builder.emit(I32Store(0));
		builder.localGet(result);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localGet(result);
		builder.localGet(length);
		builder.emit(I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET));
		builder.localGet(digitCount);
		builder.i32Const(1);
		builder.i32Sub();
		builder.localGet(isNegative);
		builder.i32Add();
		builder.localSet(index);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.i32Const(0);
				builder.localGet(number);
				builder.emit(I64Const(10));
				builder.emit(I64RemS);
				builder.emit(I32WrapI64);
				builder.i32Sub();
				builder.i32Const(48);
				builder.i32Add();
				builder.localSet(character);
				builder.localGet(result);
				builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
				builder.i32Add();
				builder.localGet(index);
				builder.i32Add();
				builder.localGet(character);
				builder.emit(I32Store8(0));
				builder.localGet(number);
				builder.emit(I64Const(10));
				builder.emit(I64DivS);
				builder.localSet(number);
				builder.localGet(number);
				builder.emit(I64Eqz);
				builder.emit(BrIf(1));
				builder.localGet(index);
				builder.i32Const(1);
				builder.i32Sub();
				builder.localSet(index);
				builder.emit(Br(0));
			});
		});
		builder.localGet(isNegative);
		builder.if_(function(builder) {
			builder.localGet(result);
			builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
			builder.i32Add();
			builder.i32Const(45);
			builder.emit(I32Store8(0));
		});
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addDynamicString(module:WasmModule, name:String, allocator:Int, strings:Map<String, Int>, program:IrProgram, ?floatString:Int):Int {
		var integerString = addIntToString(module, "__haxeon_i32_to_string", allocator),
			int64String = addInt64ToString(module, "__haxeon_i64_to_string", allocator),
			nullString = requiredStringOffset(strings, "null"),
			objectString = requiredStringOffset(strings, "Object"),
			trueString = requiredStringOffset(strings, "true"),
			falseString = requiredStringOffset(strings, "false"),
			dynamicTypes:Array<IrType> = [I64, F64, Bytes, I32];
		var builder = new WasmFunctionBuilder(name, {parameters: [I32], results: [I32]}),
			value = builder.parameter("value", 0);
		builder.localGet(value);
		builder.i32Eqz();
		builder.if_(function(builder) {
			builder.i32Const(nullString);
			builder.return_();
		});
		for (type in dynamicTypes) {
			builder.localGet(value);
			builder.emit(I32Load(0));
			builder.i32Const(WasmModuleSupport.typeId(type));
			builder.emit(I32Eq);
			builder.if_(function(builder) {
				builder.localGet(value);
				switch type {
					case I64:
						builder.emit(I64Load(WasmLayout.DYN_PAYLOAD_OFFSET));
						builder.call(builder.functionRef(int64String));
					case F64:
						if (floatString == null)
							builder.emit(Unreachable);
						else {
							builder.emit(F64Load(WasmLayout.DYN_PAYLOAD_OFFSET));
							builder.call(builder.functionRef(floatString));
						}
					case Bytes:
					default:
						builder.emit(I32Load(WasmLayout.DYN_PAYLOAD_OFFSET));
						builder.call(builder.functionRef(integerString));
				}
				builder.return_();
			});
		}
		for (object in program.objects) {
			builder.localGet(value);
			builder.emit(I32Load(0));
			builder.i32Const(WasmModuleSupport.typeId(Obj(object.name)));
			builder.emit(I32Eq);
			builder.if_(function(builder) {
				builder.i32Const(objectString);
				builder.return_();
			});
		}
		builder.localGet(value);
		builder.emit(I32Load(0));
		builder.i32Const(WasmModuleSupport.typeId(Bool));
		builder.emit(I32Eq);
		builder.if_(function(builder) {
			builder.localGet(value);
			builder.emit(I32Load(WasmLayout.DYN_PAYLOAD_OFFSET));
			builder.ifElse(function(builder) {
				builder.i32Const(trueString);
			}, function(builder) {
				builder.i32Const(falseString);
			}, I32);
			builder.return_();
		});
		// Keep dynamic object stringification total. Some objects can arrive
		// through generated/native boundaries without appearing in the program's
		// concrete object table; they still follow the standard "Object" fallback.
		builder.i32Const(objectString);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	/**
	 * Complete dynamic stringification after user functions have been assigned
	 * Wasm indices, allowing the runtime helper to call the shared Ryu formatter.
	 */
	public static function finalizeDynamicString(context:WasmLinearContext):Void {
		var dynamicString = context.functions.get("__std_string"),
			floatString = context.functions.get("runtime.Ryu.format");
		if (dynamicString == null || floatString == null)
			return;
		var replacement = addDynamicString(context.module, "__std_string.final", context.allocatorFunction, context.strings, context.program, floatString);
		context.module.setFunction(dynamicString, context.module.functionAt(replacement));
	}

	static function addStringEqual(module:WasmModule, name:String):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: [I32]}),
			left = builder.parameter("left", 0),
			right = builder.parameter("right", 1),
			leftLength = builder.local("leftLength", I32),
			rightLength = builder.local("rightLength", I32),
			index = builder.local("index", I32),
			result = builder.local("result", I32);
		// Null is distinct from every string, including the empty string.
		builder.localGet(left);
		builder.emit(I32Eqz);
		builder.localGet(right);
		builder.emit(I32Eqz);
		builder.emit(I32Or);
		builder.ifElse(function(builder) {
			builder.localGet(left);
			builder.localGet(right);
			builder.emit(I32Eq);
			builder.emit(Return);
		}, function(builder) {});
		builder.localGet(left);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localSet(leftLength);
		builder.localGet(right);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localSet(rightLength);
		builder.i32Const(0);
		builder.localSet(index);
		builder.i32Const(0);
		builder.localSet(result);
		builder.localGet(leftLength);
		builder.localGet(rightLength);
		builder.emit(I32Eq);
		builder.ifElse(function(builder) {
			builder.i32Const(1);
			builder.localSet(result);
			builder.block(function(builder) {
				builder.loop(function(builder) {
					builder.localGet(index);
					builder.localGet(leftLength);
					builder.emit(I32LtS);
					builder.ifElse(function(builder) {
						builder.localGet(left);
						builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
						builder.i32Add();
						builder.localGet(index);
						builder.i32Add();
						builder.emit(I32Load8U(0));
						builder.localGet(right);
						builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
						builder.i32Add();
						builder.localGet(index);
						builder.i32Add();
						builder.emit(I32Load8U(0));
						builder.emit(I32Eq);
						builder.ifElse(function(builder) {
							builder.localGet(index);
							builder.i32Const(1);
							builder.i32Add();
							builder.localSet(index);
							builder.emit(Br(2));
						}, function(builder) {
							builder.i32Const(0);
							builder.localSet(result);
							builder.emit(Br(3));
						});
					}, function(builder) builder.emit(Br(2)));
				});
			});
		}, function(builder) {
			builder.i32Const(0);
			builder.localSet(result);
		});
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addStringCompareFull(module:WasmModule, name:String):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: [I32]}),
			left = builder.parameter("left", 0),
			right = builder.parameter("right", 1),
			leftLength = builder.local("leftLength", I32),
			rightLength = builder.local("rightLength", I32),
			limit = builder.local("limit", I32),
			index = builder.local("index", I32),
			leftByte = builder.local("leftByte", I32),
			rightByte = builder.local("rightByte", I32),
			result = builder.local("result", I32);
		builder.localGet(left);
		builder.localGet(right);
		builder.emit(I32Eq);
		builder.if_(function(builder) {
			builder.i32Const(0);
			builder.return_();
		});
		builder.localGet(left);
		builder.i32Eqz();
		builder.if_(function(builder) {
			builder.i32Const(-1);
			builder.return_();
		});
		builder.localGet(right);
		builder.i32Eqz();
		builder.if_(function(builder) {
			builder.i32Const(1);
			builder.return_();
		});
		builder.localGet(left);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localSet(leftLength);
		builder.localGet(right);
		builder.emit(I32Load(WasmLayout.STRING_LENGTH_OFFSET));
		builder.localSet(rightLength);
		builder.localGet(leftLength);
		builder.localGet(rightLength);
		builder.emit(I32LtS);
		builder.ifElse(function(builder) {
			builder.localGet(leftLength);
		}, function(builder) {
			builder.localGet(rightLength);
		}, I32);
		builder.localSet(limit);
		builder.i32Const(0);
		builder.localSet(index);
		builder.i32Const(0);
		builder.localSet(result);
		builder.block(function(builder) {
			builder.loop(function(builder) {
				builder.localGet(index);
				builder.localGet(limit);
				builder.emit(I32LtS);
				builder.i32Eqz();
				builder.emit(BrIf(1));
				builder.localGet(left);
				builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
				builder.i32Add();
				builder.localGet(index);
				builder.i32Add();
				builder.emit(I32Load8U(0));
				builder.localSet(leftByte);
				builder.localGet(right);
				builder.i32Const(WasmLayout.STRING_DATA_OFFSET);
				builder.i32Add();
				builder.localGet(index);
				builder.i32Add();
				builder.emit(I32Load8U(0));
				builder.localSet(rightByte);
				builder.localGet(leftByte);
				builder.localGet(rightByte);
				builder.i32Sub();
				builder.localSet(result);
				builder.localGet(result);
				builder.i32Eqz();
				builder.i32Eqz();
				builder.if_(function(builder) builder.emit(Br(2)));
				builder.localGet(index);
				builder.i32Const(1);
				builder.i32Add();
				builder.localSet(index);
				builder.emit(Br(0));
			});
		});
		builder.localGet(result);
		builder.i32Eqz();
		builder.if_(function(builder) {
			builder.localGet(leftLength);
			builder.localGet(rightLength);
			builder.i32Sub();
			builder.localSet(result);
		});
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function addMathIsNaN(module:WasmModule, name:String):Int
		return module.addFunction(WasmFunctionBuilder.fromRaw(name, {parameters: [F64], results: [I32]}, [],
			[LocalGet(0), LocalGet(0), F64Eq, I32Eqz, Return]));

	static function addDynamicEqual(module:WasmModule, name:String, stringEqual:Int):Int {
		var builder = new WasmFunctionBuilder(name, {parameters: [I32, I32], results: [I32]}),
			left = builder.parameter("left", 0),
			right = builder.parameter("right", 1),
			result = builder.local("result", I32),
			leftType = builder.local("leftType", I32),
			rightType = builder.local("rightType", I32);
		builder.i32Const(0);
		builder.localSet(result);
		builder.localGet(left);
		builder.localGet(right);
		builder.emit(I32Eq);
		builder.ifElse(function(builder) {
			builder.localGet(left);
			builder.i32Eqz();
			builder.ifElse(function(builder) {
				builder.i32Const(1);
				builder.localSet(result);
			}, function(builder) {
				builder.localGet(left);
				builder.emit(I32Load(0));
				builder.i32Const(WasmModuleSupport.typeId(F64));
				builder.emit(I32Eq);
				builder.ifElse(function(builder) {
					builder.localGet(left);
					builder.emit(F64Load(WasmLayout.DYN_PAYLOAD_OFFSET));
					builder.localGet(right);
					builder.emit(F64Load(WasmLayout.DYN_PAYLOAD_OFFSET));
					builder.emit(F64Eq);
					builder.localSet(result);
				}, function(builder) {
					builder.i32Const(1);
					builder.localSet(result);
				});
			});
		}, function(builder) {
			builder.localGet(left);
			builder.i32Eqz();
			builder.ifElse(function(_) {}, function(builder) {
				builder.localGet(right);
				builder.i32Eqz();
				builder.ifElse(function(_) {}, function(builder) {
					builder.localGet(left);
					builder.emit(I32Load(0));
					builder.localSet(leftType);
					builder.localGet(right);
					builder.emit(I32Load(0));
					builder.localSet(rightType);
					builder.localGet(leftType);
					builder.localGet(rightType);
					builder.emit(I32Eq);
					builder.ifElse(function(builder) {
						builder.localGet(leftType);
						builder.i32Const(WasmModuleSupport.typeId(Bytes));
						builder.emit(I32Eq);
						builder.ifElse(function(builder) {
							builder.localGet(left);
							builder.localGet(right);
							builder.call(builder.functionRef(stringEqual));
							builder.localSet(result);
						}, function(builder) {
							builder.localGet(leftType);
							builder.i32Const(WasmModuleSupport.typeId(I32));
							builder.emit(I32Eq);
							builder.ifElse(function(builder) {
								builder.localGet(left);
								builder.emit(I32Load(WasmLayout.DYN_PAYLOAD_OFFSET));
								builder.localGet(right);
								builder.emit(I32Load(WasmLayout.DYN_PAYLOAD_OFFSET));
								builder.emit(I32Eq);
								builder.localSet(result);
							}, function(builder) {
								builder.localGet(leftType);
								builder.i32Const(WasmModuleSupport.typeId(Bool));
								builder.emit(I32Eq);
								builder.ifElse(function(builder) {
									builder.localGet(left);
									builder.emit(I32Load(WasmLayout.DYN_PAYLOAD_OFFSET));
									builder.localGet(right);
									builder.emit(I32Load(WasmLayout.DYN_PAYLOAD_OFFSET));
									builder.emit(I32Eq);
									builder.localSet(result);
								}, function(builder) {
									builder.localGet(leftType);
									builder.i32Const(WasmModuleSupport.typeId(F64));
									builder.emit(I32Eq);
									builder.ifElse(function(builder) {
										builder.localGet(left);
										builder.emit(F64Load(WasmLayout.DYN_PAYLOAD_OFFSET));
										builder.localGet(right);
										builder.emit(F64Load(WasmLayout.DYN_PAYLOAD_OFFSET));
										builder.emit(F64Eq);
										builder.localSet(result);
									}, function(builder) {
										builder.localGet(leftType);
										builder.i32Const(WasmModuleSupport.typeId(I64));
										builder.emit(I32Eq);
										builder.ifElse(function(builder) {
											builder.localGet(left);
											builder.emit(I64Load(WasmLayout.DYN_PAYLOAD_OFFSET));
											builder.localGet(right);
											builder.emit(I64Load(WasmLayout.DYN_PAYLOAD_OFFSET));
											builder.emit(I64Eq);
											builder.localSet(result);
										}, function(_) {});
									});
								});
							});
						});
					}, function(_) {});
				});
			});
		});
		builder.localGet(result);
		builder.return_();
		return module.addFunction(builder.finish());
	}

	static function requiredStringOffset(strings:Map<String, Int>, value:String):Int {
		var offset = strings.get(value);
		if (offset == null)
			throw 'Missing Wasm string data for "$value"';
		return offset;
	}

	static function resultTypes(type:IrType):Array<WasmValueType>
		return type == Void ? [] : [WasmModuleSupport.requireValueType(type)];
}
