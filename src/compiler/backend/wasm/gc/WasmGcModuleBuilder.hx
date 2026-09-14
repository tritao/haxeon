package compiler.backend.wasm.gc;

import compiler.backend.Backend.BackendOptions;
import compiler.backend.Backend.BackendResult;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.ir.Ir.IrCNative;
import compiler.ir.Ir.IrNative;
import compiler.ir.IrFunction;
import compiler.ir.IrVerifier;
import compiler.backend.wasm.WasmModuleSupport.WasmClosureTypes;
import compiler.backend.wasm.WasmFunctionLower;
import compiler.backend.wasm.WasmCfgAnalysis;
import compiler.backend.wasm.WasmEncoder;
import compiler.backend.wasm.WasmExceptionLowering;
import compiler.backend.wasm.gc.WasmGcMaps;
import compiler.backend.wasm.gc.WasmGcTypePlan;
import compiler.backend.wasm.gc.WasmGcContext;
import compiler.backend.wasm.gc.WasmGcFunctionContext;
import compiler.backend.wasm.gc.WasmGcInterop;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmLocal;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmPatch;
import compiler.backend.wasm.gc.WasmGcRepresentation;
import compiler.backend.wasm.WasmRepresentation.WasmLoweringKind;
import compiler.backend.wasm.WasmRepresentation.WasmRepresentationSet;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;

/** Owns construction and lowering of a complete Wasm GC module. */
class WasmGcModuleBuilder {
	public static function compile(program:IrProgram, options:BackendOptions, patchChanged:Null<Array<String>>):BackendResult {
		if (options.importMemory == true
			|| (options.memoryBase != null && options.memoryBase != 0)
			|| options.memoryContract != null
			|| options.wasmMemoryStats == true)
			throw "Wasm GC lowering does not use linear-memory options";
		IrVerifier.verify(program);
		var preferredEntry = WasmModuleSupport.hasFunction(program,
			"main") ? "main" : WasmModuleSupport.hasFunction(program, "Main.main") ? "Main.main" : program.entryPoint,
			exportedFunctions = options.exports == null ? [] : options.exports,
			roots = exportedFunctions.copy();
		if (WasmModuleSupport.hasFunction(program, "__init"))
			roots.push("__init");
		var reachable = WasmModuleSupport.reachableFunctions(program, preferredEntry, roots);
		validateGcSubset(program, reachable, preferredEntry);
		var usedNatives = WasmModuleSupport.reachableNatives(program, reachable),
			usedCNatives = reachableGcCNatives(program, reachable),
			requiresScratchMemory = false,
			requiresLinearMemory = false;
		for (native in program.cNatives)
			if (usedCNatives.exists(native.name)) {
				if ((native.result == ManagedBytes && native.pointerLength != null) || native.fixedResult != null)
					requiresLinearMemory = true;
				for (mode in native.argumentModes)
					switch mode {
						case BytesInput(_) | BytesInputOutput(_) | BytesOutput(_) | BytesSize | Output | InputOutput | FixedInput(_, _, _) |
							FixedValue(_, _, _) | FixedOutput(_, _, _) | FixedInputOutput(_, _, _):
							requiresScratchMemory = true;
						case Value:
					}
			}
		for (native in program.natives)
			if (usedNatives.exists(native.name) && native.symbol == "__wasm_memory_load_i32")
				requiresLinearMemory = true;

		var plan = new WasmGcTypePlan(program),
			module = new WasmModule(options.debugNames ? "haxeon" : null),
			globals:Map<String, Int> = [],
			functions:Map<String, Int> = [],
			methods:Map<String, String> = [],
			gcContext = new WasmGcContext(module, plan, functions, globals, methods),
			gcRepresentation = new WasmGcRepresentation(gcContext);
		plan.addTo(module);
		var staticData = WasmModuleSupport.placeStaticData(program, module, 8, reachable),
			hasStaticData = staticData.addresses.iterator().hasNext();
		var scratchTop = -1;
		if (requiresScratchMemory || requiresLinearMemory || hasStaticData) {
			module.memoryMin = WasmModuleSupport.memoryPages(staticData.end);
			module.exportMemory = requiresScratchMemory || requiresLinearMemory;
		}
		if (requiresScratchMemory) {
			scratchTop = module.globals.length;
			module.globals.push({type: I32, mutable: true, init: [I32Const(staticData.end)]});
		}
		addGcCNativeImports(module, functions, program, usedCNatives);
		addGcMapRuntimeFunctions(module, functions, plan, program, usedNatives);
		addGcRuntimeNativeFunctions(module, functions, plan, gcRepresentation, program, usedNatives);
		addGcMapProjectionFunctions(module, functions, plan, program, reachable);
		var scratchAllocator = -1;
		if (requiresScratchMemory) {
			scratchAllocator = addGcScratchAllocator(module, scratchTop);
		}
		var gcInterop = new WasmGcInterop(gcContext, scratchTop, scratchAllocator, gcPointerReleaseFunctionIndices(program, reachable, functions)),
			representation:WasmRepresentationSet = new WasmRepresentationSet(gcRepresentation, gcRepresentation, gcRepresentation, gcInterop,
				function(context) {
					var functionContext = new WasmGcFunctionContext(gcContext, context.irFunction, context.exceptionTag,
						context.allocateLocal), functionRepresentation = gcRepresentation.forFunctionContext(functionContext),
						functionInterop = gcInterop.forFunctionContext(functionContext);
					return new WasmRepresentationSet(functionRepresentation, functionRepresentation, functionRepresentation, functionInterop, null);
				});
		var exceptionTagType:Null<Int> = WasmModuleSupport.hasExceptions(program) ? module.typeIndex({
			parameters: [representation.values.valueType(Dyn)],
			results: []
		}) : null,
			exceptionTag:Null<Int> = exceptionTagType == null ? null : 0;
		module.exceptionTagType = exceptionTagType;
		for (field in program.staticFields) {
			globals.set(field.name, module.globals.length);
			module.globals.push({type: representation.values.valueType(field.type), mutable: true, init: representation.values.zeroValue(field.type)});
		}
		for (object in program.objects)
			for (method in object.methods)
				methods.set(object.name + "." + method.name, method.functionName);
		for (fn in program.functions) {
			if (!reachable.exists(fn.name) || (fn.name == "__entry" && preferredEntry != "__entry"))
				continue;
			var type = plan.wasmFunctionType([for (argument in fn.arguments) argument.type], fn.result);
			functions.set(fn.name, module.addFunction(new WasmFunction(fn.name, type)));
		}
		var closureTypes = collectGcClosureTypes(module, plan, program);
		addGcClosureThunks(module, plan, functions, program, reachable);
		var tableSlots = WasmModuleSupport.buildTableSlots(module, functions);

		for (fn in program.functions) {
			if (!reachable.exists(fn.name) || (fn.name == "__entry" && preferredEntry != "__entry"))
				continue;
			var functionIndex = WasmModuleSupport.requiredFunctionIndex(functions, fn.name);
			module.setFunction(functionIndex,
				WasmFunctionLower.lower(module, fn, gcContext.functions, module.functionType(functionIndex), null, -1, 0, 0, 0, gcContext.globals, [],
					gcContext.methods, closureTypes, tableSlots, exceptionTag, [], program, representation, staticData.addresses));
		}
		module.exportTable = module.tableMin != null;
		module.customSections.push({name: "haxeon.patch", bytes: WasmPatch.manifest(program, patchChanged)});
		module.customSections.push({name: "haxeon.patch.slots", bytes: WasmPatch.tableManifest(tableSlots)});
		var entry = functions.get(preferredEntry);
		if (entry == null)
			throw 'Wasm GC entry point $preferredEntry was not emitted';
		if (WasmModuleSupport.hasFunction(program, "__init"))
			module.start = functions.get("__init");
		module.exports.push({name: "main", functionIndex: entry});
		for (exported in exportedFunctions) {
			var exportIndex = functions.get(exported);
			if (exportIndex == null)
				throw 'Wasm GC export "$exported" is not a reachable function';
			module.exports.push({name: exported, functionIndex: exportIndex});
		}
		WasmExceptionLowering.lower(module);
		return {target: options.target, bytes: WasmEncoder.encode(module)};
	}

	static function validateGcSubset(program:IrProgram, reachable:Map<String, Bool>, preferredEntry:String):Void {
		var usedNatives = WasmModuleSupport.reachableNatives(program, reachable),
			directCNatives = WasmModuleSupport.reachableCNatives(program, reachable),
			usedCNatives = reachableGcCNatives(program, reachable);
		for (native in program.natives)
			if (usedNatives.exists(native.name) && !isSupportedGcNative(program, native.name)) {
				throw 'Wasm GC lowering does not support runtime native "${native.name}" yet';
			}
		for (native in program.cNatives)
			if (usedCNatives.exists(native.name)) {
				if (directCNatives.exists(native.name) && isGcPointerRelease(program, native))
					throw 'Wasm GC native release function "${native.name}" is callable only by owned pointer or byte-result cleanup';
				if (isGcPointerRelease(program, native))
					validateGcPointerReleaseImport(native);
				else
					validateGcCNative(native);
				if (WasmModuleSupport.isGcNativePointerType(native.result) && native.pointerOwnership == "owned") {
					if (native.pointerRelease == null)
						throw 'Wasm GC C native "${native.name}" is missing its owned pointer release symbol';
					validateGcPointerRelease(native, requiredCNativeBySymbol(program, native.pointerRelease));
				}
				if (native.result == ManagedBytes && native.pointerLength != null) {
					var lengthNative = requiredCNativeBySymbol(program, native.pointerLength);
					validateGcCNative(lengthNative);
					validateGcPointerLength(native, lengthNative);
					if (native.pointerOwnership == "owned") {
						if (native.pointerRelease == null)
							throw 'Wasm GC C native "${native.name}" is missing its owned pointer release symbol';
						validateGcPointerRelease(native, requiredCNativeBySymbol(program, native.pointerRelease));
					}
				}
			}
		var declaredFunctions:Map<String, Bool> = [];
		for (fn in program.functions)
			declaredFunctions.set(fn.name, true);
		var declaredCNatives:Map<String, Bool> = [];
		for (native in program.cNatives)
			declaredCNatives.set(native.name, true);
		for (fn in program.functions) {
			if (!reachable.exists(fn.name) || (fn.name == "__entry" && preferredEntry != "__entry"))
				continue;
			var cfg = new WasmCfgAnalysis(fn);
			for (blockId in cfg.graph.order)
				for (located in cfg.graph.block(blockId).instructions)
					switch located.value {
						case Phi(_, _), ConstVoid(_), ConstInt(_, _), ConstFloat(_, _), ConstBool(_, _), ConstNull(_), TypeValue(_, _), GlobalGet(_, _),
							GlobalSet(_, _), Add(_, _, _), Sub(_, _, _), Mul(_, _, _), Div(_, _, _), Mod(_, _, _), BitAnd(_, _, _), BitXor(_, _, _),
							BitOr(_, _, _), ShiftLeft(_, _, _), ShiftRight(_, _, _), UnsignedShiftRight(_, _, _), Less(_, _, _), LessEqual(_, _, _),
							Equal(_, _, _), NewObject(_, _), FieldGet(_, _, _), FieldSet(_, _, _), ArrayGet(_, _, _), ArraySet(_, _, _), ArraySize(_, _),
							IteratorNew(_, _), IteratorHasNext(_, _), IteratorNext(_, _), MakeEnum(_, _, _, _), EnumIndex(_, _), EnumField(_, _, _, _),
							IntToFloat(_, _), IntToInt64(_, _), FloatToInt(_, _), BeginTry(_, _), EndTry(_), Catch(_):
						case ConstString(_, _), StaticDataAddress(_, _):
						case ToDyn(_, _), SafeCast(_, _), ToVirtual(_, _):
						case Call(_, name, _) if (declaredFunctions.exists(name) || isSupportedGcNative(program, name)):
						case CNativeCall(_, name, _) if (declaredCNatives.exists(name)):
						case StaticClosure(_, name) if (declaredFunctions.exists(name) || isSupportedGcNative(program, name)):
						case InstanceClosure(_, name, receiver) if (declaredFunctions.exists(name) && isObjectReference(receiver.type)):
						case CallClosure(_, closure, _) if (isFunctionType(closure.type)):
						case MethodCall(_, receiver, _, _) if (isObjectReference(receiver.type) || isVirtualReference(receiver.type)):
						default:
							throw 'Wasm GC lowering does not support instruction ${Std.string(located.value)} in "${fn.name}" yet';
					}
		}
	}

	static function isObjectReference(type:IrType):Bool
		return switch type {
			case Obj(_): true;
			default: false;
		};

	static function isVirtualReference(type:IrType):Bool
		return switch type {
			case Virtual(_): true;
			default: false;
		};

	static function isFunctionType(type:IrType):Bool
		return switch type {
			case Function(_, _): true;
			default: false;
		};

	static function addGcMapRuntimeFunctions(module:WasmModule, functions:Map<String, Int>, plan:WasmGcTypePlan, program:IrProgram,
			used:Map<String, Bool>):Void {
		for (native in program.natives)
			if (used.exists(native.name)) {
				var parts = WasmModuleSupport.mapNativeParts(native.name);
				if (parts != null)
					functions.set(native.name, WasmGcMaps.add(module, functions, plan, native, parts.mapName, parts.operation));
			}
	}

	static function addGcRuntimeNativeFunctions(module:WasmModule, functions:Map<String, Int>, plan:WasmGcTypePlan, representation:WasmGcRepresentation,
			program:IrProgram, used:Map<String, Bool>):Void {
		for (native in program.natives)
			if (used.exists(native.name) && native.name == "__string_compare_full") {
				var functionType = plan.wasmFunctionType(native.arguments, native.result),
					locals:Array<WasmLocal> = [],
					nextLocal = native.arguments.length,
					allocateLocal:WasmValueType->Int = function(type) {
						var index = nextLocal++;
						locals.push({type: type});
						return index;
					};
				var functionRepresentation = representation.forFunction({allocateLocal: allocateLocal, exceptionTag: null, irFunction: null});
				var arguments = [
					for (index in 0...native.arguments.length)
						new IrValue(index, native.name + "_argument_" + index, native.arguments[index])
				], result = new IrValue(-1, native.name + "_result", native.result), resultLocal = allocateLocal(plan.valueType(native.result)),
					bodyResult = functionRepresentation.lowerRuntimeCall(native.name, result, arguments, resultLocal,
						[for (index in 0...arguments.length) index]),
					body = switch bodyResult {
						case Handled(instructions): instructions;
						case UseDefault: throw 'Wasm GC runtime native "${native.name}" has no wrapper implementation';
					};
				body.push(LocalGet(resultLocal));
				body.push(Return);
				functions.set(native.name, module.addFunction(new WasmFunction(native.name, functionType, locals, body)));
			}
	}

	static function isSupportedGcRuntimeNative(name:String):Bool {
		if (WasmModuleSupport.mapNativeParts(name) != null)
			return true;
		return switch name {
			case "__array_alloc_i32", "__array_alloc_bool", "__array_alloc_f64", "__array_alloc_bytes", "__array_alloc_ref", "__array_push_i32",
				"__array_copy_i32", "__array_copy_bool", "__array_copy_f64", "__array_copy_bytes", "__array_copy_ref", "__array_concat_i32",
				"__array_concat_bool", "__array_concat_f64", "__array_concat_bytes", "__array_concat_ref", "__array_pop_i32", "__array_pop_bool",
				"__array_pop_f64", "__array_pop_bytes", "__array_pop_ref", "__array_reverse_i32", "__array_reverse_bool", "__array_reverse_f64",
				"__array_reverse_bytes", "__array_reverse_ref", "__array_push_bool", "__array_push_f64", "__array_push_bytes", "__array_push_ref",
				"__array_unshift_i32", "__array_unshift_bool", "__array_unshift_f64", "__array_unshift_bytes", "__array_unshift_ref", "__array_resize_i32",
				"__array_resize_bool", "__array_resize_f64", "__array_insert_i32", "__array_insert_bool", "__array_insert_f64", "__array_insert_bytes",
				"__array_insert_ref", "__array_resize_bytes", "__array_resize_ref", "__array_shift_i32", "__array_shift_bool", "__array_shift_f64",
				"__array_shift_bytes", "__array_shift_ref", "__array_splice_i32", "__array_splice_bool", "__array_splice_f64", "__array_splice_bytes",
				"__array_splice_ref", "__array_remove_i32", "__array_remove_bool", "__array_remove_f64", "__array_remove_bytes", "__array_remove_ref",
				"__array_index_of_i32", "__array_index_of_bool", "__array_index_of_f64", "__array_index_of_bytes", "__array_index_of_ref",
				"__array_slice_i32", "__array_slice_bool", "__array_slice_f64", "__array_slice_bytes", "__array_slice_ref", "__array_join_bytes",
				"__math_ceil", "Math.mathIsNaN", "__math_is_nan", "__std_int_f64", "__std_int_dynamic", "__std_string", "__std_is_of_type",
				"__exception_matches", "__reflect_is_object", "__dynamic_equal", "__f64_to_i64_bits", "__i64_to_f64_bits", "haxe.Int64.ushr",
				"haxe.Int64.compare", "haxe.Int64.make", "haxe.Int64.toInt", "__bytes_alloc", "__bytes_of_string", "__bytes_length", "__bytes_get",
				"__bytes_set", "__bytes_get_i32", "__bytes_set_i32", "getI32", "setI32", "__bytes_view", "__bytes_sub", "__bytes_compare",
				"__bytes_to_string", "__bytes_get_string", "structSlice", "structWithRoots", "structGetRoots", "__bytes_input_new", "__bytes_input_position",
				"__bytes_input_big_endian", "__bytes_input_set_big_endian", "__bytes_input_read_byte", "__bytes_input_read_i32", "__bytes_input_read_f64",
				"__bytes_input_read_string", "__bytes_input_read", "__bytes_output_new", "__bytes_output_big_endian", "__bytes_output_set_big_endian",
				"__bytes_output_write_byte", "__bytes_output_write_i32", "__bytes_output_write_f64", "__bytes_output_write_string", "__bytes_output_write",
				"__bytes_output_write_range", "__bytes_output_get_bytes", "structGetPointer", "native_pointer_close", "native_pointer_is_closed",
				"native_pointer_owned_from_slot", "__string_length", "__string_char_at", "__string_char_code_at", "__string_concat", "__string_equal",
				"__string_compare_full", "__string_index_of", "__string_index_of_from", "__string_last_index_of", "__string_last_index_of_from",
				"__string_to_lower_case", "__string_to_upper_case", "__string_split", "__string_substring", "__string_from_char_code",
				"__wasm_memory_load_i32", "__runtime_string_from_ascii": true;
			default: false;
		};
	}

	static function validateGcCNative(native:IrCNative):Void {
		if (native.argumentModes.length != native.arguments.length)
			throw 'Wasm GC C native "${native.name}" has invalid argument ABI metadata';
		if (native.pointerSize != null && native.pointerSize != 4)
			throw 'Wasm GC C native "${native.name}" requires a 32-bit HXI pointer ABI for Wasm linear scratch addresses';
		if (native.fixedResult != null
			&& (!native.fixedResult.pointerFree
				|| native.fixedResult.size <= 0
				|| native.fixedResult.size > 0x10000000
				|| native.fixedResult.alignment <= 0
				|| native.fixedResult.alignment > 0x10000
				|| (native.fixedResult.alignment & (native.fixedResult.alignment - 1)) != 0))
			throw 'Wasm GC C native "${native.name}" requires a pointer-free fixed aggregate result layout';
		for (index in 0...native.arguments.length)
			switch native.argumentModes[index] {
				case Value:
					gcCNativeValueType(native.arguments[index]);
				case BytesInput(lengthArgument):
					if (native.arguments[index] != ManagedBytes
						|| lengthArgument < 0
						|| lengthArgument >= native.arguments.length
						|| native.arguments[lengthArgument] != I32)
						throw 'Wasm GC C native "${native.name}" requires byte input followed by an I32 length';
				case BytesInputOutput(lengthArgument):
					if (native.arguments[index] != ManagedBytes
						|| lengthArgument < 0
						|| lengthArgument >= native.arguments.length
						|| native.arguments[lengthArgument] != I32)
						throw 'Wasm GC C native "${native.name}" requires mutable byte input followed by an I32 length';
				case BytesOutput(sizeArgument):
					if (native.arguments[index] != ManagedBytes
						|| sizeArgument < 0
						|| sizeArgument >= native.arguments.length
						|| native.arguments[sizeArgument] != ManagedBytes
						|| native.argumentModes[sizeArgument] != BytesSize)
						throw 'Wasm GC C native "${native.name}" requires a GC byte size pointer for output buffers';
				case BytesSize:
					if (native.arguments[index] != ManagedBytes)
						throw 'Wasm GC C native "${native.name}" requires a GC byte view for output size pointers';
				case FixedInput(size, alignment, pointerFree) | FixedValue(size, alignment, pointerFree) | FixedOutput(size, alignment, pointerFree) |
					FixedInputOutput(size, alignment, pointerFree):
					if (native.arguments[index] != ManagedBytes
						|| !pointerFree
						|| size <= 0
						|| size > 0x10000000
						|| alignment <= 0
						|| alignment > 0x10000
						|| (alignment & (alignment - 1)) != 0)
						throw 'Wasm GC C native "${native.name}" requires a managed byte buffer with a valid fixed aggregate layout';
				case Output | InputOutput:
					if (native.arguments[index] != ManagedBytes)
						throw 'Wasm GC C native "${native.name}" requires a managed byte buffer for scalar output pointers';
			}
		switch native.result {
			case Void:
			case I32, Bool, I64, F64:
				gcCNativeValueType(native.result);
			case ManagedBytes if (native.fixedResult != null):
			case ManagedBytes if (native.pointerLength != null):
				if (native.pointerOwnership != "borrowed" && native.pointerOwnership != "owned")
					throw 'Wasm GC C native "${native.name}" requires borrowed or owned pointer metadata';
			case Abstract("native_pointer")
				if (native.pointerLength == null
					&& (native.pointerOwnership == "borrowed" || (native.pointerOwnership == "owned" && native.pointerRelease != null))):
			case Abstract("native_pointer"):
				throw 'Wasm GC C native "${native.name}" requires borrowed or releasable owned opaque pointer metadata';
			case _:
				throw 'Wasm GC C native "${native.name}" has unsupported result type ${Std.string(native.result)}';
		}
	}

	static function addGcMapProjectionFunctions(module:WasmModule, functions:Map<String, Int>, plan:WasmGcTypePlan, program:IrProgram,
			reachable:Map<String, Bool>):Void {
		for (fn in program.functions) {
			if (!reachable.exists(fn.name))
				continue;
			var cfg = new WasmCfgAnalysis(fn);
			for (blockId in cfg.graph.order)
				for (located in cfg.graph.block(blockId).instructions)
					switch located.value {
						case Call(output, name, _) if (output.type != Void):
							var parts = WasmModuleSupport.mapNativeParts(name);
							if (parts != null && (parts.operation == "keys" || parts.operation == "values")) {
								var native:Null<IrNative> = null;
								for (candidate in program.natives)
									if (candidate.name == name)
										native = candidate;
								if (native == null)
									throw 'Wasm GC map projection "$name" has no runtime declaration';
								var projectionName = WasmGcMaps.projectionName(name, output.type);
								if (!functions.exists(projectionName))
									functions.set(projectionName,
										WasmGcMaps.addProjectionForCall(module, plan, native, parts.mapName, parts.operation, output.type));
							}
						default:
					}
		}
	}

	static function validateGcPointerLength(pointer:IrCNative, length:IrCNative):Void {
		if (length.result != I32 || pointer.arguments.length != length.arguments.length)
			throw 'Wasm GC C native "${pointer.name}" has an incompatible byte-result length import';
		for (index in 0...pointer.arguments.length)
			if (!Type.enumEq(pointer.arguments[index], length.arguments[index])
				|| pointer.argumentModes[index] != Value
				|| length.argumentModes[index] != Value)
				throw 'Wasm GC C native "${pointer.name}" requires scalar value arguments for its byte-result length import';
	}

	static function validateGcPointerRelease(pointer:IrCNative, release:IrCNative):Void {
		if (pointer.pointerOwnership != "owned"
			|| pointer.pointerRelease != release.symbol
			|| release.result != Void
			|| release.arguments.length != 1
			|| !isGcNativePointerArgument(release.arguments[0])
			|| release.argumentModes[0] != Value)
			throw 'Wasm GC C native "${pointer.name}" requires a void release import accepting one raw native pointer';
	}

	static function validateGcPointerReleaseImport(release:IrCNative):Void {
		if (release.result != Void
			|| release.arguments.length != 1
			|| !isGcNativePointerArgument(release.arguments[0])
			|| release.argumentModes[0] != Value)
			throw 'Wasm GC C release import "${release.name}" must accept one raw native pointer and return void';
	}

	static function isGcNativePointerArgument(type:IrType):Bool
		return switch type {
			case ManagedBytes | Abstract("native_pointer"): true;
			case _: false;
		};

	static function gcCNativeValueType(type:IrType):WasmValueType
		return switch type {
			case I32, Bool: I32;
			case I64: I64;
			case F64: F64;
			case Abstract("native_pointer"): I32;
			case _: throw 'Wasm GC C ABI supports scalar arguments only, got ${Std.string(type)}';
		};

	static function addGcCNativeImports(module:WasmModule, functions:Map<String, Int>, program:IrProgram, used:Map<String, Bool>):Void {
		for (native in program.cNatives) {
			if (!used.exists(native.name))
				continue;
			var parameters:Array<WasmValueType> = [];
			if (isGcPointerRelease(program, native))
				parameters.push(I32);
			else
				for (index in 0...native.arguments.length)
					parameters.push(switch native.argumentModes[index] {
						case BytesInput(_) | BytesInputOutput(_) | BytesOutput(_) | BytesSize | Output | InputOutput | FixedInput(_, _, _) |
							FixedValue(_, _, _) | FixedOutput(_, _, _) | FixedInputOutput(_, _, _): I32;
						case Value: gcCNativeValueType(native.arguments[index]);
					});
			var type:WasmFunctionType = {
				parameters: parameters,
				results: switch native.result {
					case Void: [];
					case ManagedBytes if (native.fixedResult != null): [I32];
					case ManagedBytes if (native.pointerLength != null): [I32];
					case _: [gcCNativeValueType(native.result)];
				}
			}, importModule = native.library == null
				|| native.library == "" ? "env" : native.library, importName = native.symbol == null
					|| native.symbol == "" ? native.name : native.symbol;
			functions.set(native.name, module.addImport(importModule, importName, type));
		}
	}

	static function addGcScratchAllocator(module:WasmModule, scratchTop:Int):Int {
		// Keep C pointers aligned even after arbitrary byte-slice allocations, including over-aligned structs.
		var body:Array<WasmInstruction> = [
			GlobalGet(scratchTop),
			LocalGet(1),
			I32Const(1),
			I32Sub,
			I32Add,
			I32Const(0),
			LocalGet(1),
			I32Sub,
			I32And,
			LocalTee(2),
			LocalGet(0),
			I32Add,
			LocalTee(3),
			GlobalSet(scratchTop),
			LocalGet(3),
			I32Const(65535),
			I32Add,
			I32Const(16),
			I32ShrU,
			LocalSet(4),
			MemorySize,
			LocalSet(5),
			LocalGet(5),
			LocalGet(4),
			I32LtS,
			If(null),
			LocalGet(4),
			LocalGet(5),
			I32Sub,
			MemoryGrow,
			I32Const(-1),
			I32Eq,
			If(null),
			Unreachable,
			End,
			End,
			LocalGet(2),
			Return
		];
		var type:WasmFunctionType = {parameters: [I32, I32], results: [I32]};
		return module.addFunction(new WasmFunction("__haxeon_gc_ffi_scratch_alloc", type, [{type: I32}, {type: I32}, {type: I32}, {type: I32}], body));
	}

	static function isSupportedGcNative(program:IrProgram, name:String):Bool {
		if (isSupportedGcRuntimeNative(name))
			return true;
		for (native in program.natives)
			if (native.name == name)
				return isSupportedGcRuntimeNative(native.symbol);
		return false;
	}

	static function reachableGcCNatives(program:IrProgram, reachable:Map<String, Bool>):Map<String, Bool> {
		var result = WasmModuleSupport.reachableCNatives(program, reachable);
		for (native in program.cNatives)
			if (result.exists(native.name)) {
				if (native.result == ManagedBytes && native.pointerLength != null) {
					result.set(requiredCNativeBySymbol(program, native.pointerLength).name, true);
					if (native.pointerOwnership == "owned" && native.pointerRelease != null)
						result.set(requiredCNativeBySymbol(program, native.pointerRelease).name, true);
				} else if (WasmModuleSupport.isGcNativePointerType(native.result)
					&& native.pointerOwnership == "owned"
					&& native.pointerRelease != null)
					result.set(requiredCNativeBySymbol(program, native.pointerRelease).name, true);
			}
		for (symbol in gcPointerReleaseSymbols(program, reachable).keys())
			result.set(requiredCNativeBySymbol(program, symbol).name, true);
		return result;
	}

	static function isGcPointerRelease(program:IrProgram, candidate:IrCNative):Bool {
		for (native in program.cNatives)
			if (native.pointerOwnership == "owned"
				&& native.pointerRelease == candidate.symbol
				&& ((native.result == ManagedBytes && native.pointerLength != null)
					|| (WasmModuleSupport.isGcNativePointerType(native.result) && native.pointerLength == null)))
				return true;
		return false;
	}

	static function requiredCNativeBySymbol(program:IrProgram, symbol:String):IrCNative {
		for (native in program.cNatives)
			if (native.symbol == symbol)
				return native;
		throw 'Wasm GC byte result references missing length import "$symbol"';
	}

	static function collectGcClosureTypes(module:WasmModule, plan:WasmGcTypePlan, program:IrProgram):Map<String, WasmClosureTypes> {
		var result:Map<String, WasmClosureTypes> = [];
		for (fn in program.functions)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case CallClosure(_, closure, _):
							recordGcClosureType(module, plan, result, closure.type, false);
						case StaticClosure(output, _):
							recordGcClosureType(module, plan, result, output.type, false);
						case InstanceClosure(output, _, _):
							recordGcClosureType(module, plan, result, output.type, true);
						default:
					}
		return result;
	}

	static function recordGcClosureType(module:WasmModule, plan:WasmGcTypePlan, closureTypes:Map<String, WasmClosureTypes>, closureType:IrType,
			includeInstance:Bool):Void {
		var arguments = switch closureType {
			case Function(args, _): args;
			default: throw 'Wasm GC closure has a non-function type ${Std.string(closureType)}';
		}, resultType = switch closureType {
			case Function(_, result): result;
			default: Void;
		}, key = Std.string(closureType), staticType = module.typeIndex(plan.wasmFunctionType(arguments, resultType)), existing = closureTypes.get(key);
		if (existing == null) {
			existing = {staticType: staticType, instanceType: null};
			closureTypes.set(key, existing);
		}
		if (includeInstance) {
			var instanceType = module.typeIndex({
				parameters: [Ref({nullable: true, heap: Any})].concat([for (argument in arguments) plan.valueType(argument)]),
				results: switch resultType {
					case Void: [];
					default: [plan.valueType(resultType)];
				}
			});
			if (existing.instanceType == null)
				existing.instanceType = instanceType;
			else if (existing.instanceType != instanceType)
				throw 'Wasm GC closure signature ${Std.string(closureType)} has conflicting instance call types';
		}
	}

	static function addGcClosureThunks(module:WasmModule, plan:WasmGcTypePlan, functions:Map<String, Int>, program:IrProgram,
			reachable:Map<String, Bool>):Void {
		var targets:Map<String, Bool> = [];
		for (fn in program.functions)
			if (reachable.exists(fn.name))
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case InstanceClosure(_, target, _):
								targets.set(target, true);
							default:
						}
		var names = [for (name in targets.keys()) name];
		names.sort(Reflect.compare);
		for (targetName in names) {
			var target = findFunction(program, targetName);
			if (target == null || target.arguments.length == 0)
				throw 'Wasm GC instance closure target "$targetName" has no receiver parameter';
			var receiverType = switch target.arguments[0].type {
				case Obj(name): name;
				default: throw 'Wasm GC instance closure target "$targetName" has unsupported receiver type ${Std.string(target.arguments[0].type)}';
			}, thunkName = gcClosureThunkName(targetName), functionIndex = functions.get(targetName);
			if (functionIndex == null)
				throw 'Wasm GC instance closure target "$targetName" is not reachable';
			if (functions.exists(thunkName))
				throw 'Wasm GC closure thunk name collides with function "$thunkName"';
			var parameters = [Ref({nullable: true, heap: Any})].concat([for (argument in target.arguments.slice(1)) plan.valueType(argument.type)]),
				results = switch target.result {
					case Void: [];
					default: [plan.valueType(target.result)];
				},
				type:WasmFunctionType = {parameters: parameters, results: results},
				thunkIndex = module.addFunction(new WasmFunction(thunkName, type));
			functions.set(thunkName, thunkIndex);
			var body:Array<WasmInstruction> = [
				LocalGet(0),
				RefCast({nullable: false, heap: Type(plan.objectType(receiverType))})
			];
			for (index in 1...target.arguments.length)
				body.push(LocalGet(index));
			body.push(Call(functionIndex));
			body.push(Return);
			module.setFunction(thunkIndex, new WasmFunction(thunkName, type, [], body));
		}
	}

	static function findFunction(program:IrProgram, name:String):Null<IrFunction> {
		for (fn in program.functions)
			if (fn.name == name)
				return fn;
		return null;
	}

	public static inline function gcClosureThunkName(target:String):String
		return "__haxeon_gc_closure_thunk_" + target;

	static function gcPointerReleaseSymbols(program:IrProgram, reachable:Map<String, Bool>):Map<String, Bool> {
		var result:Map<String, Bool> = [],
			usedCNatives = WasmModuleSupport.reachableCNatives(program, reachable);
		for (native in program.cNatives)
			if (usedCNatives.exists(native.name)
				&& native.pointerOwnership == "owned"
				&& native.pointerRelease != null
				&& ((WasmModuleSupport.isGcNativePointerType(native.result) && native.pointerLength == null)
					|| (native.result == ManagedBytes && native.pointerLength != null)))
				result.set(native.pointerRelease, true);
		for (fn in program.functions)
			if (reachable.exists(fn.name)) {
				var strings:Map<Int, String> = [];
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case ConstString(output, value):
								strings.set(output.id, value);
							case _:
						}
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case Call(_, name, arguments) if (runtimeNativeSymbol(program, name) == "native_pointer_owned_from_slot"):
								if (arguments.length == 7) {
									var release = strings.get(arguments[5].id);
									if (release != null && release != "")
										result.set(release, true);
								}
							case _:
						}
			}
		return result;
	}

	static function runtimeNativeSymbol(program:IrProgram, name:String):String {
		for (native in program.natives)
			if (native.name == name)
				return native.symbol;
		return name;
	}

	static function gcPointerReleaseFunctionIndices(program:IrProgram, reachable:Map<String, Bool>, functions:Map<String, Int>):Map<String, Int> {
		var result:Map<String, Int> = [],
			symbols = [for (symbol in gcPointerReleaseSymbols(program, reachable).keys()) symbol];
		symbols.sort(Reflect.compare);
		for (symbol in symbols) {
			var release = requiredCNativeBySymbol(program, symbol),
				functionIndex = functions.get(release.name);
			if (functionIndex == null)
				throw 'Wasm GC has no imported release function "$symbol"';
			result.set(symbol, functionIndex);
		}
		return result;
	}
}
