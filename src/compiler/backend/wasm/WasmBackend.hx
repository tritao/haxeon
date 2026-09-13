package compiler.backend.wasm;

import compiler.backend.Backend;
import compiler.backend.Backend.BackendOptions;
import compiler.backend.Backend.BackendResult;
import compiler.backend.Backend.BackendTarget;
import compiler.backend.MemoryContract.MemoryContractCodec;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrCNative;
import compiler.ir.Ir.IrCNativeArgumentMode;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrTerminator;
import compiler.ir.Ir.IrBlock;
import compiler.ir.IrVerifier;
import compiler.ir.IrFunction;
import compiler.ir.IrOperands;
import haxe.io.Bytes as HaxeBytes;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmLocal;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmPatch.WasmPatchArtifact;
import compiler.backend.wasm.WasmStructurer.WasmLoopInfo;
import compiler.backend.wasm.WasmLayout.WasmFieldLayout;
import compiler.backend.wasm.WasmGcRoots.WasmSafepoint;
import compiler.backend.wasm.WasmRepresentation.WasmRepresentationSet;
import compiler.backend.wasm.WasmRepresentation.WasmFunctionRepresentationContext;
import compiler.backend.wasm.WasmRepresentation.WasmGcRepresentation;
import compiler.backend.wasm.WasmGcMaps;

typedef WasmClosureTypes = {
	final staticType:Int;
	var instanceType:Null<Int>;
}

/** First self-hosted Wasm backend: scalar lowering with explicit CFG fallback. */
class WasmBackend implements Backend {
	public function new() {}

	public function compile(program:IrProgram, options:BackendOptions):BackendResult {
		return compileInternal(program, options, null);
	}

	/**
	 * Builds a replacement Wasm patch artifact after the semantic ABI planner has
	 * confirmed that table publication is safe. The module remains self-contained
	 * for now so its runtime dependencies are validated by the same encoder as a
	 * full build; the filtered manifest is what the host publishes atomically.
	 */
	public function compilePatch(previous:Null<IrProgram>, program:IrProgram, changed:Array<String>, options:BackendOptions):WasmPatchArtifact {
		var decision = WasmPatch.plan(previous, program);
		switch decision {
			case Patch:
			default:
				throw 'Wasm patch rejected by semantic ABI: ${Std.string(decision)}';
		}
		var result = compileInternal(program, options, changed);
		return {
			bytes: result.bytes,
			manifest: WasmPatch.manifest(program, changed),
			decision: decision,
			changed: changed.copy()
		};
	}

	function compileInternal(program:IrProgram, options:BackendOptions, patchChanged:Null<Array<String>>):BackendResult {
		var target = WasmTarget.forBackend(options.target, options.debugNames);
		if (target.referenceModel == Gc)
			return compileGcInternal(program, options, patchChanged);
		if (target.referenceModel == Linear32)
			return WasmLinearModuleBuilder.compile(program, options, patchChanged, target);
		throw "Wasm backend target " + Std.string(options.target) + " is not implemented yet";
	}

	function compileGcInternal(program:IrProgram, options:BackendOptions, patchChanged:Null<Array<String>>):BackendResult {
		if (options.importMemory == true
			|| (options.memoryBase != null && options.memoryBase != 0)
			|| options.memoryContract != null
			|| options.wasmMemoryStats == true)
			throw "Wasm GC lowering does not use linear-memory options";
		IrVerifier.verify(program);
		var preferredEntry = hasFunction(program, "main") ? "main" : hasFunction(program, "Main.main") ? "Main.main" : program.entryPoint,
			exportedFunctions = options.exports == null ? [] : options.exports,
			roots = exportedFunctions.copy();
		if (hasFunction(program, "__init"))
			roots.push("__init");
		var reachable = reachableFunctions(program, preferredEntry, roots);
		validateGcSubset(program, reachable, preferredEntry);
		var usedNatives = reachableNatives(program, reachable),
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
			gcRepresentation = new WasmGcRepresentation(plan),
			representation:WasmRepresentationSet = WasmRepresentationSet.gc(gcRepresentation),
			module = new WasmModule(options.debugNames ? "haxeon" : null),
			globals:Map<String, Int> = [],
			functions:Map<String, Int> = [],
			methods:Map<String, String> = [];
		plan.addTo(module);
		var staticData = placeStaticData(program, module, 8, reachable),
			hasStaticData = staticData.addresses.iterator().hasNext();
		WasmFunctionLower.setStaticDataAddresses(staticData.addresses);
		var scratchTop = -1;
		if (requiresScratchMemory || requiresLinearMemory || hasStaticData) {
			module.memoryMin = memoryPages(staticData.end);
			module.exportMemory = requiresScratchMemory || requiresLinearMemory;
		}
		if (requiresScratchMemory) {
			scratchTop = module.globals.length;
			module.globals.push({type: I32, mutable: true, init: [I32Const(staticData.end)]});
		}
		addGcCNativeImports(module, functions, program, usedCNatives);
		gcRepresentation.configureNativePointerReleases(gcPointerReleaseFunctionIndices(program, reachable, functions));
		addGcMapRuntimeFunctions(module, functions, plan, program, usedNatives);
		addGcRuntimeNativeFunctions(module, functions, plan, gcRepresentation, program, usedNatives);
		addGcMapProjectionFunctions(module, functions, plan, program, reachable);
		if (requiresScratchMemory) {
			var scratchAllocator = addGcScratchAllocator(module, scratchTop);
			gcRepresentation.configureCNativeScratch(scratchTop, scratchAllocator);
		}
		var exceptionTagType:Null<Int> = hasExceptions(program) ? module.typeIndex({parameters: [representation.values.valueType(Dyn)], results: []}) : null,
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
		var tableSlots = buildTableSlots(module, functions);

		for (fn in program.functions) {
			if (!reachable.exists(fn.name) || (fn.name == "__entry" && preferredEntry != "__entry"))
				continue;
			var functionIndex = requiredFunctionIndex(functions, fn.name);
			module.setFunction(functionIndex,
				WasmFunctionLower.lower(fn, functions, module.functionType(functionIndex), null, -1, 0, 0, 0, globals, [], methods, closureTypes, tableSlots,
					exceptionTag, [], program, representation));
		}
		module.exportTable = module.tableMin != null;
		module.customSections.push({name: "haxeon.patch", bytes: WasmPatch.manifest(program, patchChanged)});
		module.customSections.push({name: "haxeon.patch.slots", bytes: WasmPatch.tableManifest(tableSlots)});
		var entry = functions.get(preferredEntry);
		if (entry == null)
			throw 'Wasm GC entry point $preferredEntry was not emitted';
		if (hasFunction(program, "__init"))
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
		var usedNatives = reachableNatives(program, reachable),
			directCNatives = reachableCNatives(program, reachable),
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
				if (isGcNativePointerType(native.result) && native.pointerOwnership == "owned") {
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
				var parts = mapNativeParts(native.name);
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
					body = functionRepresentation.lowerRuntimeCall(native.name, result, arguments, resultLocal, [for (index in 0...arguments.length) index]);
				if (body == null)
					throw 'Wasm GC runtime native "${native.name}" has no wrapper implementation';
				body.push(LocalGet(resultLocal));
				body.push(Return);
				functions.set(native.name, module.addFunction(new WasmFunction(native.name, functionType, locals, body)));
			}
	}

	static function isSupportedGcRuntimeNative(name:String):Bool {
		if (mapNativeParts(name) != null)
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
				"__bytes_to_string", "__bytes_get_string", "structSlice", "__bytes_input_new", "__bytes_input_position", "__bytes_input_big_endian",
				"__bytes_input_set_big_endian", "__bytes_input_read_byte", "__bytes_input_read_i32", "__bytes_input_read_f64", "__bytes_input_read_string",
				"__bytes_input_read", "__bytes_output_new", "__bytes_output_big_endian", "__bytes_output_set_big_endian", "__bytes_output_write_byte",
				"__bytes_output_write_i32", "__bytes_output_write_f64", "__bytes_output_write_string", "__bytes_output_write", "__bytes_output_write_range",
				"__bytes_output_get_bytes", "structGetPointer", "native_pointer_close", "native_pointer_is_closed", "native_pointer_owned_from_slot",
				"__string_length", "__string_char_at", "__string_char_code_at", "__string_concat", "__string_equal", "__string_compare_full",
				"__string_index_of", "__string_index_of_from", "__string_last_index_of", "__string_last_index_of_from", "__string_to_lower_case",
				"__string_to_upper_case", "__string_split", "__string_substring", "__string_from_char_code", "__wasm_memory_load_i32",
				"__runtime_string_from_ascii": true;
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
							var parts = mapNativeParts(name);
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

	public static function isGcNativePointerType(type:IrType):Bool
		return switch type {
			case Abstract("native_pointer"): true;
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

	public static function addMemoryStatExport(module:WasmModule, name:String, body:Array<WasmInstruction>):Void {
		var index = module.addFunction(new WasmFunction(name, {parameters: [], results: [I32]}, [], body));
		module.exports.push({name: name, functionIndex: index});
	}

	public static function addCNativeImports(module:WasmModule, functions:Map<String, Int>, program:IrProgram, used:Map<String, Bool>):Void {
		for (native in program.cNatives) {
			if (!used.exists(native.name))
				continue;
			var type:WasmFunctionType = {
				parameters: [for (argument in native.arguments) requireValueType(argument)],
				results: resultTypes(native.result)
			};
			var importModule = native.library == null || native.library == "" ? "env" : native.library,
				importName = native.symbol == null || native.symbol == "" ? native.name : native.symbol;
			functions.set(native.name, module.addImport(importModule, importName, type));
		}
	}

	public static function reachableNatives(program:IrProgram, reachable:Map<String, Bool>):Map<String, Bool> {
		var result:Map<String, Bool> = [];
		for (fn in program.functions)
			if (reachable.exists(fn.name))
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case Call(_, name, _):
								result.set(name, true);
							default:
						}
		return result;
	}

	public static function reachableCNatives(program:IrProgram, reachable:Map<String, Bool>):Map<String, Bool> {
		var result:Map<String, Bool> = [];
		for (fn in program.functions)
			if (reachable.exists(fn.name))
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case CNativeCall(_, name, _):
								result.set(name, true);
							default:
						}
		return result;
	}

	static function reachableGcCNatives(program:IrProgram, reachable:Map<String, Bool>):Map<String, Bool> {
		var result = reachableCNatives(program, reachable);
		for (native in program.cNatives)
			if (result.exists(native.name)) {
				if (native.result == ManagedBytes && native.pointerLength != null) {
					result.set(requiredCNativeBySymbol(program, native.pointerLength).name, true);
					if (native.pointerOwnership == "owned" && native.pointerRelease != null)
						result.set(requiredCNativeBySymbol(program, native.pointerRelease).name, true);
				} else if (isGcNativePointerType(native.result) && native.pointerOwnership == "owned" && native.pointerRelease != null)
					result.set(requiredCNativeBySymbol(program, native.pointerRelease).name, true);
			}
		for (symbol in gcPointerReleaseSymbols(program, reachable).keys())
			result.set(requiredCNativeBySymbol(program, symbol).name, true);
		return result;
	}

	static function gcPointerReleaseSymbols(program:IrProgram, reachable:Map<String, Bool>):Map<String, Bool> {
		var result:Map<String, Bool> = [],
			usedCNatives = reachableCNatives(program, reachable);
		for (native in program.cNatives)
			if (usedCNatives.exists(native.name)
				&& native.pointerOwnership == "owned"
				&& native.pointerRelease != null
				&& ((isGcNativePointerType(native.result) && native.pointerLength == null)
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

	static function isGcPointerRelease(program:IrProgram, candidate:IrCNative):Bool {
		for (native in program.cNatives)
			if (native.pointerOwnership == "owned"
				&& native.pointerRelease == candidate.symbol
				&& ((native.result == ManagedBytes && native.pointerLength != null)
					|| (isGcNativePointerType(native.result) && native.pointerLength == null)))
				return true;
		return false;
	}

	static function requiredCNativeBySymbol(program:IrProgram, symbol:String):IrCNative {
		for (native in program.cNatives)
			if (native.symbol == symbol)
				return native;
		throw 'Wasm GC byte result references missing length import "$symbol"';
	}

	public static function memoryPages(bytes:Int):Int
		return Std.int(Math.ceil(bytes / 65536.0));

	public static function resultTypes(type:IrType):Array<WasmValueType>
		return type == Void ? [] : [requireValueType(type)];

	public static function mapNativeParts(name:String):Null<{mapName:String, operation:String}> {
		if (!StringTools.startsWith(name, "__map_"))
			return null;
		var separator = name.lastIndexOf("_");
		if (separator <= 6 || separator == name.length - 1)
			return null;
		return {
			mapName: name.substring(2, separator),
			operation: name.substring(separator + 1, name.length)
		};
	}

	public static function collectClosureTypes(module:WasmModule, program:IrProgram):Map<String, WasmClosureTypes> {
		var result:Map<String, WasmClosureTypes> = [];
		for (fn in program.functions)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case CallClosure(_, closure, _):
							switch closure.type {
								case Function(arguments, resultType):
									var type:WasmFunctionType = {
										parameters: [for (argument in arguments) requireValueType(argument)],
										results: resultTypes(resultType)
									};
									var key = Std.string(closure.type);
									if (!result.exists(key)) result.set(key, {staticType: module.typeIndex(type), instanceType: null});
								default:
							}
						case InstanceClosure(output, name, _):
							var target:Null<IrFunction> = null;
							for (candidate in program.functions)
								if (candidate.name == name)
									target = candidate;
							if (target == null || target.arguments.length == 0)
								throw 'Wasm instance closure target "$name" has no receiver';
							var closureArguments = switch output.type {
								case Function(arguments, _): arguments;
								default: throw 'Wasm instance closure has an invalid function type';
							};
							var resultType = switch output.type {
								case Function(_, result): result;
								default: Void;
							};
							var staticType = module.typeIndex({
								parameters: [for (argument in closureArguments) requireValueType(argument)],
								results: resultTypes(resultType)
							}), instanceType = module.typeIndex({
								parameters: [requireValueType(target.arguments[0].type)].concat([for (argument in closureArguments) requireValueType(argument)]),
								results: resultTypes(resultType)
							});
							var key = Std.string(output.type),
								existing = result.get(key);
							if (existing == null)
								result.set(key, {staticType: staticType, instanceType: instanceType});
							else
								existing.instanceType = instanceType;
						default:
					}
		return result;
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

	public static function buildTableSlots(module:WasmModule, functions:Map<String, Int>):Map<String, Int> {
		var names = [for (fn in module.functions) if (functions.exists(fn.name)) fn.name];
		names.sort(Reflect.compare);
		var slots:Map<String, Int> = [];
		for (index in 0...names.length) {
			slots.set(names[index], index);
			module.tableElements.push(requiredFunctionIndex(functions, names[index]));
		}
		module.tableMin = names.length;
		return slots;
	}

	public static function stringBytes(value:String):HaxeBytes {
		var raw = HaxeBytes.ofString(value),
			bytes = HaxeBytes.alloc(WasmLayout.STRING_DATA_OFFSET + raw.length + 1);
		bytes.setInt32(0, typeId(Bytes));
		bytes.setInt32(WasmLayout.STRING_LENGTH_OFFSET, raw.length);
		bytes.setInt32(WasmLayout.ARRAY_CAPACITY_OFFSET, raw.length);
		for (index in 0...raw.length)
			bytes.set(WasmLayout.STRING_DATA_OFFSET + index, raw.get(index));
		return bytes;
	}

	public static function zeroValue(type:IrType):Array<WasmInstruction>
		return switch type {
			case I64: [I64Const(0)];
			case F64: [F64Const(0.0)];
			case Void: [];
			default: [I32Const(0)];
		};

	public static function align(value:Int, boundary:Int):Int
		return (value + boundary - 1) & ~(boundary - 1);

	public static function placeStaticData(program:IrProgram, module:WasmModule, start:Int, reachable:Map<String, Bool>):{addresses:Map<String, Int>, end:Int} {
		var addresses:Map<String, Int> = [], next = start;
		for (fn in program.functions)
			if (reachable.exists(fn.name))
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case StaticDataAddress(_, bytes):
								var key = staticDataKey(bytes);
								if (!addresses.exists(key)) {
									var offset = align(next, 8),
									data = HaxeBytes.alloc(bytes.length);
									for (index in 0...bytes.length)
										data.set(index, bytes[index]);
									module.data.push({offset: offset, bytes: data});
									addresses.set(key, offset);
									next = offset + data.length;
								}
							default:
						}
		return {addresses: addresses, end: align(next, 8)};
	}

	public static function staticDataKey(bytes:Array<Int>):String {
		var digits = "0123456789abcdef", key = new StringBuf();
		for (byte in bytes) {
			key.add(digits.charAt(byte >>> 4));
			key.add(digits.charAt(byte & 15));
		}
		return key.toString();
	}

	public static function hasFunction(program:IrProgram, name:String):Bool {
		for (fn in program.functions)
			if (fn.name == name)
				return true;
		return false;
	}

	public static function hasExceptions(program:IrProgram):Bool {
		for (fn in program.functions) {
			for (block in fn.blocks) {
				for (located in block.instructions)
					switch located.value {
						case BeginTry(_, _), EndTry(_), Catch(_):
							return true;
						default:
					}
				if (block.terminator != null)
					switch block.terminator.value {
						case Throw(_), Rethrow(_):
							return true;
						default:
					}
			}
		}
		return false;
	}

	public static function reachableFunctions(program:IrProgram, entry:String, ?additionalRoots:Array<String>):Map<String, Bool> {
		var byName:Map<String, IrFunction> = [],
			reachable:Map<String, Bool> = [],
			pending:Array<String> = [entry];
		if (additionalRoots != null)
			for (root in additionalRoots)
				pending.push(root);
		for (fn in program.functions)
			byName.set(fn.name, fn);
		while (pending.length > 0) {
			var name = pending.pop();
			if (reachable.exists(name) || !byName.exists(name))
				continue;
			reachable.set(name, true);
			var fn = byName.get(name);
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case Call(_, target, _):
							enqueueFunction(target, byName, pending);
						case StaticClosure(_, target), InstanceClosure(_, target, _):
							enqueueFunction(target, byName, pending);
						case MethodCall(_, object, method, _):
							switch object.type {
								case Obj(objectName):
									for (candidate in program.objects)
										if (isObjectSubtype(program, candidate.name, objectName))
											enqueueFunction(findMethod(program, candidate.name, method), byName, pending);
								case Virtual(interfaceName):
									for (candidate in program.objects)
										if (implementsInterface(program, candidate.name, interfaceName))
											enqueueFunction(findMethod(program, candidate.name, method), byName, pending);
								default:
							}
						default:
					}
		}
		return reachable;
	}

	static function enqueueFunction(name:Null<String>, byName:Map<String, IrFunction>, pending:Array<String>):Void
		if (name != null && byName.exists(name))
			pending.push(name);

	static function findMethod(program:IrProgram, objectName:String, methodName:String):Null<String> {
		for (object in program.objects)
			if (object.name == objectName) {
				for (method in object.methods)
					if (method.name == methodName)
						return method.functionName;
				return object.base == null ? null : findMethod(program, object.base, methodName);
			}
		return null;
	}

	static function isObjectSubtype(program:IrProgram, actual:String, expected:String):Bool {
		if (actual == expected)
			return true;
		for (object in program.objects)
			if (object.name == actual)
				return object.base != null && isObjectSubtype(program, object.base, expected);
		return false;
	}

	static function implementsInterface(program:IrProgram, objectName:String, interfaceName:String):Bool {
		for (object in program.objects)
			if (object.name == objectName) {
				for (implemented in object.interfaces)
					if (interfaceExtends(program, implemented, interfaceName))
						return true;
				return object.base != null && implementsInterface(program, object.base, interfaceName);
			}
		return false;
	}

	static function interfaceExtends(program:IrProgram, actual:String, expected:String):Bool {
		if (actual == expected)
			return true;
		for (interfaceDecl in program.interfaces)
			if (interfaceDecl.name == actual)
				for (base in interfaceDecl.bases)
					if (interfaceExtends(program, base, expected))
						return true;
		return false;
	}

	public static function typeId(type:IrType):Int {
		var identity = switch type {
			case Iterator(_): Abstract("realtime_iterator");
			default: type;
		}, text = Std.string(identity), hash:Int = -2128831035;
		for (index in 0...text.length) {
			hash = Std.int(hash ^ text.charCodeAt(index));
			hash = Std.int(hash * 16777619);
		}
		return hash;
	}

	static function programFunction(program:IrProgram, name:String):IrFunction {
		for (fn in program.functions)
			if (fn.name == name)
				return fn;
		throw 'Unknown IR function "$name"';
	}

	public static function requiredGlobal(globals:Map<String, Int>, name:String):Int {
		if (!globals.exists(name))
			throw 'Unknown Wasm global "$name"';
		return globals.get(name);
	}

	public static function requiredFunctionIndex(functions:Map<String, Int>, name:String):Int {
		if (!functions.exists(name))
			throw 'Unknown Wasm function "$name"';
		return functions.get(name);
	}

	public static function requireValueType(type:IrType):WasmValueType
		return switch type {
			case I32, Bool: I32;
			case I64: I64;
			case F64: F64;
			case Bytes, ManagedBytes, Dyn, TypeRef, Array(_), Enum(_), Obj(_), Abstract(_), Virtual(_), Iterator(_), Function(_, _): I32;
			default: throw 'Wasm scalar backend does not yet support IR type ${Std.string(type)}';
		};
}

class WasmFunctionLower {
	static var activeProgram:IrProgram;
	static var activeRepresentation:WasmRepresentationSet;
	static var activeTableSlots:Map<String, Int>;
	static var activeStaticDataAddresses:Map<String, Int>;
	static var activeElidedDynamicArrayCasts:Map<Int, IrValue>;
	static var activeArrayTemps:{
		len:Int,
		capacity:Int,
		data:Int,
		required:Int
	};
	static var activeExceptionState:Null<{
		handler:Int,
		exception:Int,
		saved:Map<Int, Int>,
		blocks:Map<Int, Int>,
		tag:Int
	}>;
	static var activeGcRootState:Null<{
		frame:Int,
		top:Int,
		frameTop:Int,
		slots:Array<Int>,
		slotByValue:Map<Int, Int>,
		live:Map<Int, Map<Int, Array<Int>>>,
		size:Int
	}>;

	public static function setStaticDataAddresses(addresses:Map<String, Int>):Void
		activeStaticDataAddresses = addresses;

	static function requiredLocal(locals:Map<Int, Int>, valueId:Int):Int {
		if (!locals.exists(valueId))
			throw 'Unknown Wasm local for value $valueId';
		return locals.get(valueId);
	}

	static function elidedDynamicArrayCasts(fn:IrFunction, representation:WasmRepresentationSet):Map<Int, IrValue> {
		// A GC Array<Dynamic> wrapper cannot cast an element-typed array wrapper. When
		// flow narrowing is immediately erased again, preserve the original anyref.
		var result:Map<Int, IrValue> = [];
		if (!Std.isOfType(representation.values, WasmGcRepresentation))
			return result;
		var candidates:Map<Int, IrValue> = [],
			invalid:Map<Int, Bool> = [],
			uses:Map<Int, Int> = [];
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case SafeCast(output, value) if (value.type == Dyn && isDynamicArrayType(output.type)):
						candidates.set(output.id, value);
					default:
				}
		for (block in fn.blocks)
			for (located in block.instructions)
				for (input in IrOperands.inputs(located.value))
					if (candidates.exists(input.id))
						switch located.value {
							case ToDyn(_, value) if (value.id == input.id):
								uses.set(input.id, (uses.get(input.id) ?? 0) + 1);
							default:
								invalid.set(input.id, true);
						}
		for (valueId in candidates.keys())
			if (!invalid.exists(valueId) && uses.get(valueId) == 1)
				result.set(valueId, candidates.get(valueId));
		return result;
	}

	static function isDynamicArrayType(type:IrType):Bool
		return switch type {
			case Array(Dyn): true;
			default: false;
		};

	static function requiredBlockIndex(blocks:Map<Int, Int>, blockId:Int):Int {
		if (!blocks.exists(blockId))
			throw 'Unknown Wasm block $blockId';
		return blocks.get(blockId);
	}

	public static function lower(fn:IrFunction, functions:Map<String, Int>, type:WasmFunctionType, layout:WasmLayout, allocator:Int, rootTop:Int,
			rootFrameTop:Int, rootLimit:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>,
			closureTypes:Map<String, WasmClosureTypes>, tableSlots:Map<String, Int>, exceptionTag:Null<Int>, rootPoints:Array<WasmSafepoint>,
			program:IrProgram, representation:WasmRepresentationSet):WasmFunction {
		activeProgram = program;
		activeTableSlots = tableSlots;
		var analysis = new WasmCfgAnalysis(fn),
			placement = new WasmValuePlacement(fn, representation.values),
			valueLocals = placement.values,
			locals = placement.locals;
		var functionContext:WasmFunctionRepresentationContext = {
			allocateLocal: function(type) return placement.allocate(type),
			exceptionTag: exceptionTag,
			irFunction: fn
		};
		activeRepresentation = representation.forFunction(functionContext);
		activeElidedDynamicArrayCasts = elidedDynamicArrayCasts(fn, activeRepresentation);
		activeArrayTemps = {
			len: placement.allocate(I32),
			capacity: placement.allocate(I32),
			data: placement.allocate(I32),
			required: placement.allocate(I32)
		};
		var rootLocals:Array<Int> = [],
			rootIds:Map<Int, Bool> = [],
			live:Map<Int, Map<Int, Array<Int>>> = [];
		for (point in rootPoints) {
			var blockLive = live.get(point.block);
			if (blockLive == null) {
				blockLive = [];
				live.set(point.block, blockLive);
			}
			blockLive.set(point.instruction, point.liveReferences);
			for (valueId in point.liveReferences) {
				rootIds.set(valueId, true);
			}
		}
		var rootValueIds = [for (valueId in rootIds.keys()) valueId];
		rootValueIds.sort(function(left, right) return left - right);
		var slotByValue:Map<Int, Int> = [];
		for (index in 0...rootValueIds.length) {
			slotByValue.set(rootValueIds[index], index);
			rootLocals.push(requiredLocal(valueLocals, rootValueIds[index]));
		}
		var rootFrame = rootLocals.length == 0 ? null : placement.allocate(I32);
		activeGcRootState = rootFrame == null ? null : {
			frame: rootFrame,
			top: rootTop,
			frameTop: rootFrameTop,
			slots: rootLocals,
			slotByValue: slotByValue,
			live: live,
			size: align(12 + rootLocals.length * 4, 8)
		};
		activeExceptionState = null;
		if (exceptionTag != null) {
			var blocks:Map<Int, Int> = [], orderIndex = 0;
			for (id in analysis.graph.order)
				blocks.set(id, orderIndex++);
			var saved:Map<Int, Int> = [];
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case BeginTry(catchBlock, _):
							if (!saved.exists(catchBlock))
								saved.set(catchBlock, placement.allocate(I32));
						default:
					}
			activeExceptionState = {
				handler: placement.allocate(I32),
				exception: placement.allocate(activeRepresentation.values.valueType(Dyn)),
				saved: saved,
				blocks: blocks,
				tag: exceptionTag
			};
		}
		var predecessor = placement.allocate(I32);
		var structurer = new WasmStructurer(fn),
			body:Array<WasmInstruction> = null;
		if (activeExceptionState == null && structurer.canUseStructured())
			try
				body = lowerStructured(fn, structurer, functions, valueLocals, predecessor, layout, allocator, globals, strings, methods, closureTypes)
			catch (_:Dynamic) {}
		if (body == null) {
			var pc = placement.allocate(I32);
			body = lowerDispatcher(fn, analysis, functions, valueLocals, pc, predecessor, layout, allocator, globals, strings, methods, closureTypes);
		}
		var rootState = activeGcRootState;
		if (rootState != null) {
			var rooted:Array<WasmInstruction> = rootPrologue(rootState, rootLimit);
			rooted = rooted.concat(body);
			if (exceptionTag != null) {
				var exceptionLocal = placement.allocate(activeRepresentation.values.valueType(Dyn)),
					protectedBody:Array<WasmInstruction> = [Try(null)];
				protectedBody = protectedBody.concat(rooted);
				protectedBody = protectedBody.concat([Catch(exceptionTag), LocalSet(exceptionLocal)]);
				restoreRoots(protectedBody);
				protectedBody = protectedBody.concat([LocalGet(exceptionLocal), Throw(exceptionTag), End, Unreachable]);
				rooted = protectedBody;
			}
			body = rooted;
		}
		body = WasmOptimizer.optimize(body);
		return new WasmFunction(fn.name, type, locals, body);
	}

	static function lowerStructured(fn:IrFunction, structurer:WasmStructurer, functions:Map<String, Int>, values:Map<Int, Int>, predecessor:Int,
			layout:WasmLayout, allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>,
			closureTypes:Map<String, WasmClosureTypes>):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = [];
		emit(body, [I32Const(-1), LocalSet(predecessor)]);
		if (!emitPath(body, fn.blocks[0].id, null, null, 0, structurer, functions, values, predecessor, [], layout, allocator, globals, strings, methods,
			closureTypes))
			throw 'Unable to structure CFG for ${fn.name}';
		body.push(Unreachable);
		return body;
	}

	static function emitPath(body:Array<WasmInstruction>, start:Int, stop:Null<Int>, activeLoop:Null<Int>, loopDepth:Int, structurer:WasmStructurer,
			functions:Map<String, Int>, values:Map<Int, Int>, predecessor:Int, visited:Array<Int>, layout:WasmLayout, allocator:Int, globals:Map<String, Int>,
			strings:Map<String, Int>, methods:Map<String, String>, closureTypes:Map<String, WasmClosureTypes>):Bool {
		var current = start;
		while (stop == null || current != stop) {
			if (visited.indexOf(current) >= 0)
				return false;
			visited.push(current);
			var block = structurer.analysis.graph.block(current);
			var loop = structurer.loops.get(block.id);
			if (loop != null) {
				if (!emitLoop(body, block, loop, structurer, functions, values, predecessor, visited, layout, allocator, globals, strings, methods,
					closureTypes))
					return false;
				if (stop != null && loop.exit == stop)
					return true;
				current = loop.exit;
				continue;
			}
			emitBlockInstructions(body, block, values, functions, predecessor, layout, allocator, globals, strings, methods, closureTypes);
			if (block.terminator == null)
				return false;
			switch block.terminator.value {
				case Return(value):
					restoreRoots(body);
					if (value.type != Void)
						body.push(LocalGet(requiredLocal(values, value.id)));
					body.push(Return);
					return true;
				case Throw(_), Rethrow(_):
					body.push(Unreachable);
					return true;
				case Jump(target):
					if (activeLoop != null && target == activeLoop) {
						setPredecessor(body, predecessor, block.id);
						body.push(Br(loopDepth));
						return true;
					}
					setPredecessor(body, predecessor, block.id);
					if (stop != null && target == stop)
						return true;
					current = target;
				case Branch(condition, yes, no):
					var merge = structurer.analysis.mergeFor(yes, no);
					if (merge == null)
						return false;
					emit(body, [LocalGet(requiredLocal(values, condition.id)), If(null)]);
					setPredecessor(body, predecessor, block.id);
					if (!emitPath(body, yes, merge, activeLoop, activeLoop == null ? 0 : loopDepth + 1, structurer, functions, values, predecessor,
						visited.copy(), layout, allocator, globals, strings, methods, closureTypes))
						return false;
					body.push(Else);
					setPredecessor(body, predecessor, block.id);
					if (!emitPath(body, no, merge, activeLoop, activeLoop == null ? 0 : loopDepth + 1, structurer, functions, values, predecessor,
						visited.copy(), layout, allocator, globals, strings, methods, closureTypes))
						return false;
					body.push(End);
					if (stop != null && merge == stop)
						return true;
					current = merge;
			}
		}
		return true;
	}

	static function emitLoop(body:Array<WasmInstruction>, block:IrBlock, loop:WasmLoopInfo, structurer:WasmStructurer, functions:Map<String, Int>,
			values:Map<Int, Int>, predecessor:Int, visited:Array<Int>, layout:WasmLayout, allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>,
			methods:Map<String, String>, closureTypes:Map<String, WasmClosureTypes>):Bool {
		if (block.terminator == null)
			return false;
		var condition:Null<IrValue> = null, whenTrue = -1, whenFalse = -1;
		switch block.terminator.value {
			case Branch(value, yes, no):
				condition = value;
				whenTrue = yes;
				whenFalse = no;
			default:
		}
		if (condition == null || (loop.body != whenTrue && loop.body != whenFalse))
			return false;
		emit(body, [Block(null), Loop(null)]);
		emitBlockInstructions(body, block, values, functions, predecessor, layout, allocator, globals, strings, methods, closureTypes);
		emit(body, [LocalGet(requiredLocal(values, condition.id)), If(null)]);
		if (loop.body == whenTrue) {
			setPredecessor(body, predecessor, block.id);
			if (!emitPath(body, loop.body, block.id, block.id, 1, structurer, functions, values, predecessor, visited.copy(), layout, allocator, globals,
				strings, methods, closureTypes))
				return false;
			body.push(Else);
			setPredecessor(body, predecessor, block.id);
			emit(body, [Br(2)]);
		} else {
			setPredecessor(body, predecessor, block.id);
			emit(body, [Br(2), Else]);
			if (!emitPath(body, loop.body, block.id, block.id, 1, structurer, functions, values, predecessor, visited.copy(), layout, allocator, globals,
				strings, methods, closureTypes))
				return false;
		}
		emit(body, [End, End, End]);
		return true;
	}

	static function emitBlockInstructions(body:Array<WasmInstruction>, block:IrBlock, values:Map<Int, Int>, functions:Map<String, Int>, predecessor:Int,
			layout:WasmLayout, allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>,
			closureTypes:Map<String, WasmClosureTypes>):Void {
		for (index in 0...block.instructions.length) {
			var located = block.instructions[index];
			// Safepoint liveness describes the instruction's entry state; snapshot before it can allocate or collect.
			snapshotRoots(body, block.id, index);
			switch located.value {
				case Phi(output, inputs):
					WasmPhiLower.emit(body, output, inputs, values, predecessor);
				default:
					lowerInstruction(body, located.value, values, functions, layout, allocator, globals, strings, methods, closureTypes);
			}
		}
	}

	static function lowerDispatcher(fn:IrFunction, analysis:WasmCfgAnalysis, functions:Map<String, Int>, values:Map<Int, Int>, pc:Int, predecessor:Int,
			layout:WasmLayout, allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>,
			closureTypes:Map<String, WasmClosureTypes>):Array<WasmInstruction> {
		var body:Array<WasmInstruction> = [], blockIndex:Map<Int, Int> = [];
		var next = 0;
		for (id in analysis.graph.order)
			blockIndex.set(id, next++);
		var exceptionState = activeExceptionState;
		emit(body, [
			I32Const(requiredBlockIndex(blockIndex, fn.blocks[0].id)),
			LocalSet(pc),
			I32Const(-1),
			LocalSet(predecessor)
		]);
		if (exceptionState != null) {
			emit(body, [I32Const(-1), LocalSet(exceptionState.handler)]);
		}
		emit(body, [Block(null), Loop(null)]);
		if (exceptionState != null)
			body.push(Try(null));
		for (index in 0...analysis.graph.order.length) {
			var block = analysis.graph.block(analysis.graph.order[index]);
			emit(body, [LocalGet(pc), I32Const(index), I32Eq, If(null)]);
			lowerBlock(body, block, values, functions, pc, predecessor, blockIndex, layout, allocator, globals, strings, methods, closureTypes);
			if (index < analysis.graph.order.length - 1)
				body.push(Else);
			else
				emit(body, [Else, Unreachable]);
		}
		for (_ in 0...analysis.graph.order.length)
			body.push(End);
		if (exceptionState == null) {
			emit(body, [Br(0), End, End, Unreachable]);
		} else {
			emit(body, [Br(1), Catch(exceptionState.tag), LocalSet(exceptionState.exception)]);
			emit(body, [LocalGet(exceptionState.handler), I32Const(-1), I32Eq, If(null)]);
			emit(body, [LocalGet(exceptionState.exception), Throw(exceptionState.tag), Else]);
			var catches = [for (catchBlock in exceptionState.saved.keys()) catchBlock];
			catches.sort(function(left, right) return left - right);
			for (catchBlock in catches) {
				emit(body, [
					LocalGet(exceptionState.handler),
					I32Const(requiredBlockIndex(blockIndex, catchBlock)),
					I32Eq,
					If(null)
				]);
				emit(body, [LocalGet(exceptionState.handler), LocalSet(pc)]);
				emit(body, [
					LocalGet(requiredLocal(exceptionState.saved, catchBlock)),
					LocalSet(exceptionState.handler)
				]);
				body.push(Else);
			}
			body.push(Unreachable);
			for (_ in catches)
				body.push(End);
			emit(body, [End, Br(1), End, End, End, Unreachable]);
		}
		return body;
	}

	public static function hasExceptions(fn:IrFunction):Bool {
		for (block in fn.blocks) {
			for (located in block.instructions)
				switch located.value {
					case BeginTry(_, _), EndTry(_), Catch(_):
						return true;
					default:
				}
			if (block.terminator != null)
				switch block.terminator.value {
					case Throw(_), Rethrow(_):
						return true;
					default:
				}
		}
		return false;
	}

	static function lowerBlock(body:Array<WasmInstruction>, block:IrBlock, values:Map<Int, Int>, functions:Map<String, Int>, pc:Int, predecessor:Int,
			blockIndex:Map<Int, Int>, layout:WasmLayout, allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>,
			closureTypes:Map<String, WasmClosureTypes>):Void {
		var exceptionState = activeExceptionState;
		for (index in 0...block.instructions.length) {
			var located = block.instructions[index];
			snapshotRoots(body, block.id, index);
			switch located.value {
				case Phi(output, inputs):
					WasmPhiLower.emit(body, output, inputs, values, predecessor);
				default:
					lowerInstruction(body, located.value, values, functions, layout, allocator, globals, strings, methods, closureTypes);
			}
		}
		if (block.terminator == null)
			throw 'Missing terminator in Wasm block ${block.id}';
		switch block.terminator.value {
			case Return(value):
				restoreRoots(body);
				if (value.type != Void)
					body.push(LocalGet(requiredLocal(values, value.id)));
				body.push(Return);
			case Throw(value), Rethrow(value):
				if (exceptionState == null)
					body.push(Unreachable);
				else
					emit(body, [LocalGet(requiredLocal(values, value.id)), Throw(exceptionState.tag)]);
			case Jump(target):
				setPcAndContinue(body, pc, predecessor, block.id, requiredBlockIndex(blockIndex, target));
			case Branch(condition, yes, no):
				emit(body, [LocalGet(requiredLocal(values, condition.id)), If(null)]);
				setPcAndContinue(body, pc, predecessor, block.id, requiredBlockIndex(blockIndex, yes));
				body.push(Else);
				setPcAndContinue(body, pc, predecessor, block.id, requiredBlockIndex(blockIndex, no));
				body.push(End);
		}
	}

	static function setPcAndContinue(body:Array<WasmInstruction>, pc:Int, predecessor:Int, sourceBlock:Int, target:Int):Void {
		emit(body, [I32Const(sourceBlock), LocalSet(predecessor), I32Const(target), LocalSet(pc)]);
	}

	static function trapOrThrow():Array<WasmInstruction> {
		var exceptionState = activeExceptionState;
		return exceptionState == null ? [Unreachable] : activeRepresentation.values.zeroValue(Dyn).concat([Throw(exceptionState.tag)]);
	}

	static function setPredecessor(body:Array<WasmInstruction>, predecessor:Int, sourceBlock:Int):Void
		emit(body, [I32Const(sourceBlock), LocalSet(predecessor)]);

	static function lowerInstruction(body:Array<WasmInstruction>, instruction:IrInstruction, values:Map<Int, Int>, functions:Map<String, Int>,
			layout:WasmLayout, allocator:Int, globals:Map<String, Int>, strings:Map<String, Int>, methods:Map<String, String>,
			closureTypes:Map<String, WasmClosureTypes>):Void {
		var exceptionState = activeExceptionState;
		switch instruction {
			case Phi(_, _):
			case ConstInt(output, value):
				emit(body, [
					output.type == I64 ? I64Const(value) : I32Const(value),
					LocalSet(requiredLocal(values, output.id))
				]);
			case ConstBool(output, value):
				emit(body, [I32Const(value ? 1 : 0), LocalSet(requiredLocal(values, output.id))]);
			case ConstFloat(output, value):
				emit(body, [F64Const(value), LocalSet(requiredLocal(values, output.id))]);
			case ConstNull(output):
				emit(body, activeRepresentation.values.nullValue(output.type, requiredLocal(values, output.id)));
			case ConstVoid(_):
			case TypeValue(output, type):
				emit(body, [I32Const(typeId(type)), LocalSet(requiredLocal(values, output.id))]);
			case ToDyn(output, value):
				var original = activeElidedDynamicArrayCasts.get(value.id),
					dynamicValue = original == null ? value : original,
					represented = activeRepresentation.values.toDynamic(dynamicValue, requiredLocal(values, output.id), requiredLocal(values, dynamicValue.id));
				if (represented != null)
					emit(body, represented);
				else
					switch value.type {
						case I32, Bool:
							emit(body, [
								I32Const(WasmLayout.DYN_I32_SIZE),
								Call(allocator),
								LocalTee(requiredLocal(values, output.id)),
								I32Const(typeId(value.type)),
								I32Store(0),
								LocalGet(requiredLocal(values, output.id)),
								LocalGet(requiredLocal(values, value.id)),
								I32Store(WasmLayout.DYN_PAYLOAD_OFFSET)
							]);
						case F64:
							emit(body, [
								I32Const(WasmLayout.DYN_F64_SIZE),
								Call(allocator),
								LocalTee(requiredLocal(values, output.id)),
								I32Const(typeId(F64)),
								I32Store(0),
								LocalGet(requiredLocal(values, output.id)),
								LocalGet(requiredLocal(values, value.id)),
								F64Store(WasmLayout.DYN_PAYLOAD_OFFSET)
							]);
						case I64:
							emit(body, [
								I32Const(WasmLayout.DYN_I64_SIZE),
								Call(allocator),
								LocalTee(requiredLocal(values, output.id)),
								I32Const(typeId(I64)),
								I32Store(0),
								LocalGet(requiredLocal(values, output.id)),
								LocalGet(requiredLocal(values, value.id)),
								I64Store(WasmLayout.DYN_PAYLOAD_OFFSET)
							]);
						default:
							emit(body, [
								LocalGet(requiredLocal(values, value.id)),
								LocalSet(requiredLocal(values, output.id))
							]);
					}
			case SafeCast(output, value):
				if (!activeElidedDynamicArrayCasts.exists(output.id)) {
					var represented = activeRepresentation.values.safeCast(output, value, requiredLocal(values, output.id), requiredLocal(values, value.id));
					if (represented != null)
						emit(body, represented);
					else
						switch output.type {
							case I32, Bool, I64, F64 if (value.type == Dyn):
								emit(body, [
									LocalGet(requiredLocal(values, value.id)),
									I32Load(0),
									I32Const(typeId(output.type)),
									I32Eq,
									If(null),
									LocalGet(requiredLocal(values, value.id)),
									load(output.type, WasmLayout.DYN_PAYLOAD_OFFSET),
									LocalSet(requiredLocal(values, output.id)),
									Else,
									Unreachable,
									End
								]);
							default:
								emit(body, [
									LocalGet(requiredLocal(values, value.id)),
									LocalSet(requiredLocal(values, output.id))
								]);
						}
				}
			case BeginTry(catchBlock, _):
				if (exceptionState == null)
					throw 'Wasm exception lowering has no active exception state';
				var saved = requiredLocal(exceptionState.saved, catchBlock),
					target = requiredBlockIndex(exceptionState.blocks, catchBlock);
				emit(body, [
					LocalGet(exceptionState.handler),
					LocalSet(saved),
					I32Const(target),
					LocalSet(exceptionState.handler)
				]);
			case EndTry(catchBlock):
				if (exceptionState == null)
					throw 'Wasm exception lowering has no active exception state';
				var saved = requiredLocal(exceptionState.saved, catchBlock);
				emit(body, [LocalGet(saved), LocalSet(exceptionState.handler)]);
			case Catch(output):
				if (exceptionState == null)
					throw 'Wasm exception lowering has no active exception state';
				emit(body, [LocalGet(exceptionState.exception), LocalSet(requiredLocal(values, output.id))]);
			case GlobalGet(output, name):
				var global = globals.get(name);
				if (global == null)
					throw 'Wasm global "$name" is not declared';
				emit(body, [GlobalGet(global), LocalSet(requiredLocal(values, output.id))]);
			case GlobalSet(name, value):
				var global = globals.get(name);
				if (global == null)
					throw 'Wasm global "$name" is not declared';
				emit(body, [LocalGet(requiredLocal(values, value.id)), GlobalSet(global)]);
			case StaticClosure(output, name):
				var functionIndex = functions.get(name);
				if (functionIndex == null)
					throw 'Wasm closure target "$name" is not emitted';
				var tableSlot = activeTableSlots.get(name);
				if (tableSlot == null)
					throw 'Wasm closure target "$name" has no stable table slot';
				var calls = activeRepresentation.calls,
					represented = calls == null ? null : calls.staticClosure(name, activeTableSlots, requiredLocal(values, output.id));
				if (represented != null)
					emit(body, represented);
				else
					emit(body, [I32Const(tableSlot * 2 + 1), LocalSet(requiredLocal(values, output.id))]);
			case CallClosure(output, closure, arguments):
				var typeInfo = closureTypes.get(Std.string(closure.type));
				if (typeInfo == null)
					throw 'Wasm closure type ${Std.string(closure.type)} has no indirect signature';
				var calls = activeRepresentation.calls,
					instanceType = typeInfo.instanceType,
					destination = output.type == Void ? -1 : requiredLocal(values, output.id),
					represented = calls == null ? null : calls.callClosure(typeInfo.staticType, instanceType, arguments, requiredLocal(values, closure.id),
						destination, [for (argument in arguments) requiredLocal(values, argument.id)]);
				if (represented != null)
					emit(body, represented);
				else if (instanceType == null) {
					for (argument in arguments)
						body.push(LocalGet(requiredLocal(values, argument.id)));
					body.push(LocalGet(requiredLocal(values, closure.id)));
					body.push(I32Const(1));
					body.push(I32ShrU);
					body.push(CallIndirect(typeInfo.staticType));
					if (output.type != Void)
						body.push(LocalSet(requiredLocal(values, output.id)));
				} else {
					body.push(LocalGet(requiredLocal(values, closure.id)));
					body.push(I32Const(1));
					body.push(I32And);
					body.push(If(null));
					for (argument in arguments)
						body.push(LocalGet(requiredLocal(values, argument.id)));
					body.push(LocalGet(requiredLocal(values, closure.id)));
					body.push(I32Const(1));
					body.push(I32ShrU);
					body.push(CallIndirect(typeInfo.staticType));
					if (output.type != Void)
						body.push(LocalSet(requiredLocal(values, output.id)));
					body.push(Else);
					body.push(LocalGet(requiredLocal(values, closure.id)));
					body.push(I32Load(WasmLayout.CLOSURE_RECEIVER_OFFSET));
					for (argument in arguments)
						body.push(LocalGet(requiredLocal(values, argument.id)));
					body.push(LocalGet(requiredLocal(values, closure.id)));
					body.push(I32Load(WasmLayout.CLOSURE_FUNCTION_OFFSET));
					body.push(CallIndirect(instanceType));
					if (output.type != Void)
						body.push(LocalSet(requiredLocal(values, output.id)));
					body.push(End);
				}
			case InstanceClosure(output, name, receiver):
				var functionIndex = functions.get(name);
				if (functionIndex == null)
					throw 'Wasm instance closure target "$name" is not emitted';
				var tableSlot = activeTableSlots.get(name);
				if (tableSlot == null)
					throw 'Wasm instance closure target "$name" has no stable table slot';
				var calls = activeRepresentation.calls,
					represented = calls == null ? null : calls.instanceClosure(name, activeTableSlots, requiredLocal(values, receiver.id),
						requiredLocal(values, output.id));
				if (represented != null)
					emit(body, represented);
				else
					emit(body, [
						I32Const(WasmLayout.CLOSURE_SIZE),
						Call(allocator),
						LocalTee(requiredLocal(values, output.id)),
						I32Const(WasmLayout.CLOSURE_TYPE_ID),
						I32Store(0),
						LocalGet(requiredLocal(values, output.id)),
						I32Const(tableSlot),
						I32Store(WasmLayout.CLOSURE_FUNCTION_OFFSET),
						LocalGet(requiredLocal(values, output.id)),
						LocalGet(requiredLocal(values, receiver.id)),
						I32Store(WasmLayout.CLOSURE_RECEIVER_OFFSET)
					]);
			case ToVirtual(output, value):
				var represented = activeRepresentation.values.toVirtual(value, requiredLocal(values, output.id), requiredLocal(values, value.id));
				if (represented != null)
					emit(body, represented);
				else
					emit(body, [
						LocalGet(requiredLocal(values, value.id)),
						LocalSet(requiredLocal(values, output.id))
					]);
			case MethodCall(output, object, methodName, arguments):
				switch object.type {
					case Obj(objectName):
						var targets = classVirtualTargets(activeProgram, objectName, methodName, functions),
							calls = activeRepresentation.calls,
							represented = targets.length == 0
								|| calls == null ? null : calls.virtualCall(output, object, arguments, targets, requiredLocal(values, object.id),
									output.type == Void ? -1 : requiredLocal(values, output.id),
									[for (argument in arguments) requiredLocal(values, argument.id)]);
						if (represented != null) emit(body, represented); else if (targets.length == 0) {
							var functionName = findMethod(activeProgram, objectName, methodName),
								functionIndex = functionName == null ? null : functions.get(functionName);
							if (functionIndex == null)
								throw 'Wasm method target "$objectName.$methodName" is not emitted';
							body.push(LocalGet(requiredLocal(values, object.id)));
							for (argument in arguments)
								body.push(LocalGet(requiredLocal(values, argument.id)));
							body.push(Call(functionIndex));
							if (output.type != Void)
								body.push(LocalSet(requiredLocal(values, output.id)));
						} else {
							for (index in 0...targets.length) {
								var target = targets[index];
								emit(body, [
									LocalGet(requiredLocal(values, object.id)),
									I32Load(0),
									I32Const(typeId(Obj(target.typeName))),
									I32Eq,
									If(null),
									LocalGet(requiredLocal(values, object.id))
								]);
								for (argument in arguments)
									body.push(LocalGet(requiredLocal(values, argument.id)));
								body.push(Call(target.functionIndex));
								if (output.type != Void)
									body.push(LocalSet(requiredLocal(values, output.id)));
								if (index < targets.length - 1)
									body.push(Else);
								else
									emit(body, [Else, Unreachable]);
							}
							for (_ in targets)
								body.push(End);
						}
					case Virtual(interfaceName):
						var targets = virtualTargets(activeProgram, interfaceName, methodName, functions);
						if (targets.length == 0)
							throw 'Wasm interface method "$interfaceName.$methodName" has no implementations';
						var calls = activeRepresentation.calls,
							represented = calls == null ? null : calls.virtualCall(output, object, arguments, targets, requiredLocal(values, object.id),
								output.type == Void ? -1 : requiredLocal(values, output.id), [for (argument in arguments) requiredLocal(values, argument.id)]);
						if (represented != null) emit(body, represented); else {
							for (index in 0...targets.length) {
								var target = targets[index];
								emit(body, [
									LocalGet(requiredLocal(values, object.id)),
									I32Load(0),
									I32Const(typeId(Obj(target.typeName))),
									I32Eq,
									If(null),
									LocalGet(requiredLocal(values, object.id))
								]);
								for (argument in arguments)
									body.push(LocalGet(requiredLocal(values, argument.id)));
								body.push(Call(target.functionIndex));
								if (output.type != Void)
									body.push(LocalSet(requiredLocal(values, output.id)));
								if (index < targets.length - 1)
									body.push(Else);
								else
									emit(body, [Else, Unreachable]);
							}
							for (_ in targets)
								body.push(End);
						}
					default:
						throw 'Wasm method call requires an object or virtual receiver';
				}
			case ConstString(output, value):
				var represented = activeRepresentation.values.constantString(value, requiredLocal(values, output.id), strings);
				if (represented != null)
					emit(body, represented);
				else {
					var pointer = strings.get(value);
					if (pointer == null)
						throw 'Wasm string literal was not placed in a data segment';
					emit(body, [I32Const(pointer), LocalSet(requiredLocal(values, output.id))]);
				}
			case StaticDataAddress(output, bytes):
				var address = activeStaticDataAddresses.get(WasmBackend.staticDataKey(bytes));
				if (address == null)
					throw "Wasm static data address was not placed in the data section";
				emit(body, [I32Const(address), LocalSet(requiredLocal(values, output.id))]);
			case MakeEnum(output, typeName, constructor, arguments):
				var represented = activeRepresentation.aggregates.makeEnum(typeName, constructor, arguments, requiredLocal(values, output.id),
					[for (argument in arguments) requiredLocal(values, argument.id)]);
				if (represented != null)
					emit(body, represented);
				else {
					var enumLayout = layout.enumType(typeName);
					emit(body, [
						I32Const(enumLayout.size),
						Call(allocator),
						LocalTee(requiredLocal(values, output.id)),
						I32Const(typeId(Enum(typeName))),
						I32Store(0),
						LocalGet(requiredLocal(values, output.id)),
						I32Const(constructor),
						I32Store(WasmLayout.HEADER_SIZE)
					]);
					var offset = WasmLayout.HEADER_SIZE + 4;
					for (argument in arguments) {
						offset = align(offset, WasmLayout.alignmentOf(argument.type));
						emit(body, [
							LocalGet(requiredLocal(values, output.id)),
							I32Const(offset),
							I32Add,
							LocalGet(requiredLocal(values, argument.id)),
							store(argument.type, 0)
						]);
						offset += WasmLayout.sizeOf(argument.type);
					}
				}
			case EnumIndex(output, value):
				var represented = activeRepresentation.aggregates.enumIndex(value, requiredLocal(values, output.id), requiredLocal(values, value.id));
				if (represented != null)
					emit(body, represented);
				else
					emit(body, [
						LocalGet(requiredLocal(values, value.id)),
						I32Load(WasmLayout.HEADER_SIZE),
						LocalSet(requiredLocal(values, output.id))
					]);
			case EnumField(output, value, constructor, field):
				var represented = activeRepresentation.aggregates.enumField(value, constructor, field, requiredLocal(values, output.id),
					requiredLocal(values, value.id));
				if (represented != null)
					emit(body, represented);
				else {
					var enumType = switch value.type {
						case Enum(name): name;
						default: throw 'Wasm enum field access requires an enum value, got ${Std.string(value.type)}';
					};
					var fieldLayout = layout.enumField(enumType, constructor, field);
					emit(body, [
						LocalGet(requiredLocal(values, value.id)),
						I32Const(fieldLayout.offset),
						I32Add,
						load(fieldLayout.type, 0),
						LocalSet(requiredLocal(values, output.id))
					]);
				}
			case IntToFloat(output, value):
				emit(body, [
					LocalGet(requiredLocal(values, value.id)),
					value.type == I64 ? F64ConvertI64S : F64ConvertI32S,
					LocalSet(requiredLocal(values, output.id))
				]);
			case IntToInt64(output, value):
				emit(body, [
					LocalGet(requiredLocal(values, value.id)),
					I64ExtendI32S,
					LocalSet(requiredLocal(values, output.id))
				]);
			case FloatToInt(output, value):
				emit(body, [
					LocalGet(requiredLocal(values, value.id)),
					I32TruncF64S,
					LocalSet(requiredLocal(values, output.id))
				]);
			case NewObject(output, typeName):
				emit(body, activeRepresentation.aggregates.newObject(typeName, requiredLocal(values, output.id)));
			case FieldGet(output, object, fieldName):
				emit(body, activeRepresentation.aggregates.fieldGet(object, fieldName, requiredLocal(values, output.id), requiredLocal(values, object.id)));
			case FieldSet(object, fieldName, value):
				emit(body, activeRepresentation.aggregates.fieldSet(object, fieldName, requiredLocal(values, object.id), requiredLocal(values, value.id)));
			case ArrayGet(output, array, index):
				var represented = activeRepresentation.aggregates.arrayGet(array, index, requiredLocal(values, output.id), requiredLocal(values, array.id),
					requiredLocal(values, index.id));
				if (represented != null)
					emit(body, represented);
				else {
					var element = arrayElement(array),
						stride = WasmLayout.arrayStride(element);
					var arrayBody:Array<WasmInstruction> = [LocalGet(requiredLocal(values, index.id)), I32Const(0), I32LtS, If(null)];
					arrayBody = arrayBody.concat(trapOrThrow());
					arrayBody = arrayBody.concat([
						Else,
						LocalGet(requiredLocal(values, index.id)),
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
						I32LtS,
						If(null),
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
						LocalGet(requiredLocal(values, index.id)),
						I32Const(stride),
						I32Mul,
						I32Add,
						load(element, 0),
						LocalSet(requiredLocal(values, output.id)),
					]);
					arrayBody.push(Else);
					arrayBody = arrayBody.concat(trapOrThrow());
					arrayBody = arrayBody.concat([End, End]);
					emit(body, arrayBody);
				}
			case ArraySet(array, index, value):
				var represented = activeRepresentation.aggregates.arraySet(array, index, value, requiredLocal(values, array.id),
					requiredLocal(values, index.id), requiredLocal(values, value.id));
				if (represented != null)
					emit(body, represented);
				else {
					var element = arrayElement(array),
						stride = WasmLayout.arrayStride(element);
					var arrayBody:Array<WasmInstruction> = [LocalGet(requiredLocal(values, index.id)), I32Const(0), I32LtS, If(null)];
					arrayBody = arrayBody.concat(trapOrThrow());
					arrayBody = arrayBody.concat([
						Else,
						LocalGet(requiredLocal(values, index.id)),
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
						I32LtS,
						If(null),
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
						LocalGet(requiredLocal(values, index.id)),
						I32Const(stride),
						I32Mul,
						I32Add,
						LocalGet(requiredLocal(values, value.id)),
						store(element, 0),
						Else
					]);
					arrayBody = arrayBody.concat([
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
						LocalSet(activeArrayTemps.len),
						LocalGet(requiredLocal(values, index.id)),
						I32Const(1),
						I32Add,
						LocalSet(activeArrayTemps.required),
						LocalGet(activeArrayTemps.required),
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
						I32LeS,
						If(null),
						Else,
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
						I32Const(2),
						I32Mul,
						LocalSet(activeArrayTemps.capacity),
						LocalGet(activeArrayTemps.capacity),
						LocalGet(activeArrayTemps.required),
						I32LtS,
						If(null),
						LocalGet(activeArrayTemps.required),
						LocalSet(activeArrayTemps.capacity),
						End,
						LocalGet(activeArrayTemps.capacity),
						I32Const(stride),
						I32Mul,
						Call(allocator),
						LocalSet(activeArrayTemps.data),
						LocalGet(activeArrayTemps.data),
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
						LocalGet(activeArrayTemps.len),
						I32Const(stride),
						I32Mul,
						MemoryCopy,
						LocalGet(requiredLocal(values, array.id)),
						LocalGet(activeArrayTemps.data),
						I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
						LocalGet(requiredLocal(values, array.id)),
						LocalGet(activeArrayTemps.capacity),
						I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
						End,
						Block(null),
						Loop(null),
						LocalGet(activeArrayTemps.len),
						LocalGet(activeArrayTemps.required),
						I32LtS,
						If(null),
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
						LocalGet(activeArrayTemps.len),
						I32Const(stride),
						I32Mul,
						I32Add,
						element == F64 ? F64Const(0.0) : I32Const(0),
						element == F64 ? F64Store(0) : I32Store(0),
						LocalGet(activeArrayTemps.len),
						I32Const(1),
						I32Add,
						LocalSet(activeArrayTemps.len),
						Br(1),
						Else,
						Br(2),
						End,
						End,
						End,
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
						LocalGet(requiredLocal(values, index.id)),
						I32Const(stride),
						I32Mul,
						I32Add,
						LocalGet(requiredLocal(values, value.id)),
						store(element, 0),
						LocalGet(requiredLocal(values, array.id)),
						LocalGet(activeArrayTemps.required),
						I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
						End,
						End
					]);
					emit(body, arrayBody);
				}
			case ArraySize(output, array):
				var represented = activeRepresentation.aggregates.arraySize(array, requiredLocal(values, output.id), requiredLocal(values, array.id));
				if (represented != null)
					emit(body, represented);
				else
					emit(body, [
						LocalGet(requiredLocal(values, array.id)),
						I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
						LocalSet(requiredLocal(values, output.id))
					]);
			case IteratorNew(output, array):
				var iteratorLocal = requiredLocal(values, output.id),
					represented = activeRepresentation.aggregates.iteratorNew(array, iteratorLocal, requiredLocal(values, array.id));
				if (represented != null)
					emit(body, represented);
				else
					emit(body, [
						I32Const(WasmLayout.ITERATOR_SIZE),
						Call(allocator),
						LocalTee(iteratorLocal),
						I32Const(typeId(Abstract("realtime_iterator"))),
						I32Store(0),
						LocalGet(iteratorLocal),
						I32Const(WasmLayout.ITERATOR_SIZE),
						I32Store(4),
						LocalGet(iteratorLocal),
						LocalGet(requiredLocal(values, array.id)),
						I32Store(WasmLayout.ITERATOR_ARRAY_OFFSET),
						LocalGet(iteratorLocal),
						I32Const(0),
						I32Store(WasmLayout.ITERATOR_POSITION_OFFSET)
					]);
			case IteratorHasNext(output, iterator):
				var iteratorLocal = requiredLocal(values, iterator.id),
					represented = activeRepresentation.aggregates.iteratorHasNext(iterator, requiredLocal(values, output.id), iteratorLocal);
				if (represented != null)
					emit(body, represented);
				else {
					var arrayOffset = WasmLayout.ITERATOR_ARRAY_OFFSET,
						positionOffset = WasmLayout.ITERATOR_POSITION_OFFSET;
					emit(body, [
						LocalGet(iteratorLocal),
						I32Eqz,
						If(I32),
						I32Const(0),
						Else,
						LocalGet(iteratorLocal),
						I32Load(arrayOffset),
						I32Eqz,
						If(I32),
						I32Const(0),
						Else,
						LocalGet(iteratorLocal),
						I32Load(positionOffset),
						LocalGet(iteratorLocal),
						I32Load(arrayOffset),
						I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
						I32LtS,
						End,
						End,
						LocalSet(requiredLocal(values, output.id))
					]);
				}
			case IteratorNext(output, iterator):
				var iteratorLocal = requiredLocal(values, iterator.id),
					represented = activeRepresentation.aggregates.iteratorNext(iterator, output, requiredLocal(values, output.id), iteratorLocal);
				if (represented != null)
					emit(body, represented);
				else {
					var arrayOffset = WasmLayout.ITERATOR_ARRAY_OFFSET,
						positionOffset = WasmLayout.ITERATOR_POSITION_OFFSET,
						stride = WasmLayout.arrayStride(output.type),
						outputLocal = requiredLocal(values, output.id);
					var iteratorBody:Array<WasmInstruction> = [LocalGet(iteratorLocal), I32Eqz, If(null)];
					iteratorBody = iteratorBody.concat(trapOrThrow());
					iteratorBody = iteratorBody.concat([Else, LocalGet(iteratorLocal), I32Load(arrayOffset), I32Eqz, If(null)]);
					iteratorBody = iteratorBody.concat(trapOrThrow());
					iteratorBody = iteratorBody.concat([
						Else,
						LocalGet(iteratorLocal),
						I32Load(positionOffset),
						LocalGet(iteratorLocal),
						I32Load(arrayOffset),
						I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
						I32LtS,
						If(null),
						LocalGet(iteratorLocal),
						I32Load(arrayOffset),
						I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
						LocalGet(iteratorLocal),
						I32Load(positionOffset),
						I32Const(stride),
						I32Mul,
						I32Add,
						load(output.type, 0),
						LocalSet(outputLocal),
						LocalGet(iteratorLocal),
						LocalGet(iteratorLocal),
						I32Load(positionOffset),
						I32Const(1),
						I32Add,
						I32Store(positionOffset),
						Else
					]);
					iteratorBody = iteratorBody.concat(trapOrThrow());
					iteratorBody = iteratorBody.concat([End, End, End]);
					emit(body, iteratorBody);
				}
			case Add(output, left, right):
				binary(body, output, left, right, values, arithmeticInstruction(left.type, F64Add, I64Add, I32Add));
			case Sub(output, left, right):
				binary(body, output, left, right, values, arithmeticInstruction(left.type, F64Sub, I64Sub, I32Sub));
			case Mul(output, left, right):
				binary(body, output, left, right, values, arithmeticInstruction(left.type, F64Mul, I64Mul, I32Mul));
			case Div(output, left, right):
				binary(body, output, left, right, values, arithmeticInstruction(left.type, F64Div, I64DivS, I32DivS));
			case Mod(output, left, right):
				binary(body, output, left, right, values, arithmeticInstruction(left.type, I32RemS, I64RemS, I32RemS));
			case BitAnd(output, left, right):
				binary(body, output, left, right, values, arithmeticInstruction(left.type, I32And, I64And, I32And));
			case BitXor(output, left, right):
				binary(body, output, left, right, values, arithmeticInstruction(left.type, I32Xor, I64Xor, I32Xor));
			case BitOr(output, left, right):
				binary(body, output, left, right, values, arithmeticInstruction(left.type, I32Or, I64Or, I32Or));
			case ShiftLeft(output, left, right):
				shift(body, output, left, right, values, arithmeticInstruction(left.type, I32Shl, I64Shl, I32Shl));
			case ShiftRight(output, left, right):
				shift(body, output, left, right, values, arithmeticInstruction(left.type, I32ShrS, I64ShrS, I32ShrS));
			case UnsignedShiftRight(output, left, right):
				shift(body, output, left, right, values, arithmeticInstruction(left.type, I32ShrU, I64ShrU, I32ShrU));
			case Less(output, left, right):
				binary(body, output, left, right, values, comparisonInstruction(left.type, F64Lt, I64LtS, I32LtS));
			case LessEqual(output, left, right):
				binary(body, output, left, right, values, comparisonInstruction(left.type, F64Le, I64LeS, I32LeS));
			case Equal(output, left, right):
				emit(body,
					activeRepresentation.values.equal(requiredLocal(values, output.id), left, right, requiredLocal(values, left.id),
						requiredLocal(values, right.id)));
			case Call(output, name, arguments):
				var runtimeName = name;
				for (native in activeProgram.natives)
					if (native.name == name)
						runtimeName = native.symbol;
				var outputLocal = output.type == Void ? -1 : requiredLocal(values, output.id),
					interop = activeRepresentation.interop,
					represented = interop == null ? null : interop.lowerRuntimeCall(runtimeName, output, arguments, outputLocal,
						[for (argument in arguments) requiredLocal(values, argument.id)]);
				if (represented != null)
					emit(body, represented);
				else if (!lowerInt64Native(body, output, name, arguments, values)) {
					for (argument in arguments)
						body.push(LocalGet(requiredLocal(values, argument.id)));
					var functionIndex = functions.get(name);
					var mapParts = WasmBackend.mapNativeParts(name);
					if (mapParts != null && output.type != Void && (mapParts.operation == "keys" || mapParts.operation == "values")) {
						var projectionIndex = functions.get(WasmGcMaps.projectionName(name, output.type));
						if (projectionIndex != null)
							functionIndex = projectionIndex;
					}
					if (functionIndex == null)
						throw 'Wasm call to unsupported native or missing function "$name"';
					body.push(Call(functionIndex));
					if (output.type != Void)
						body.push(LocalSet(requiredLocal(values, output.id)));
				}
			case CNativeCall(output, name, arguments):
				var native:Null<IrCNative> = null;
				for (candidate in activeProgram.cNatives)
					if (candidate.name == name)
						native = candidate;
				if (native == null)
					throw 'Wasm C native call "$name" has no declared import contract';
				var importIndex = functions.get(name);
				if (importIndex == null)
					throw 'Wasm C native call "$name" has no declared import contract';
				var pointerLengthImportIndex = -1,
					pointerReleaseImportIndex = -1;
				if ((native.result == ManagedBytes && native.pointerLength != null)
					|| (WasmBackend.isGcNativePointerType(native.result) && native.pointerOwnership == "owned")) {
					var lengthNative:Null<IrCNative> = null;
					if (native.result == ManagedBytes && native.pointerLength != null) {
						for (candidate in activeProgram.cNatives)
							if (candidate.symbol == native.pointerLength)
								lengthNative = candidate;
						if (lengthNative != null) {
							var importedLength = functions.get(lengthNative.name);
							if (importedLength != null)
								pointerLengthImportIndex = importedLength;
						}
					}
					if (native.pointerOwnership == "owned" && native.pointerRelease != null)
						for (candidate in activeProgram.cNatives)
							if (candidate.symbol == native.pointerRelease) {
								var importedRelease = functions.get(candidate.name);
								if (importedRelease != null)
									pointerReleaseImportIndex = importedRelease;
							}
				}
				var outputLocal = output.type == Void ? -1 : requiredLocal(values, output.id),
					interop = activeRepresentation.interop,
					represented = interop == null ? null : interop.lowerCNativeCall(native, arguments, outputLocal,
						[for (argument in arguments) requiredLocal(values, argument.id)], importIndex, pointerLengthImportIndex, pointerReleaseImportIndex);
				if (represented != null)
					emit(body, represented);
				else {
					var bytesDataPointer = functions.get("__haxeon_bytes_data_pointer");
					if (bytesDataPointer == null)
						throw "Wasm byte data pointer helper is missing";
					for (argument in arguments)
						nativeArgument(body, argument, values, bytesDataPointer);
					body.push(Call(importIndex));
					if (output.type != Void)
						body.push(LocalSet(requiredLocal(values, output.id)));
				}
		}
	}

	static function lowerInt64Native(body:Array<WasmInstruction>, output:IrValue, name:String, arguments:Array<IrValue>, values:Map<Int, Int>):Bool {
		if (name == "haxe.Int64.toInt") {
			if (arguments.length != 1 || output.type != I32)
				throw "Invalid haxe.Int64.toInt Wasm native signature";
			body.push(LocalGet(requiredLocal(values, arguments[0].id)));
			body.push(I32WrapI64);
			body.push(LocalSet(requiredLocal(values, output.id)));
			return true;
		}
		if (name == "haxe.Int64.compare") {
			if (arguments.length != 2 || output.type != I32)
				throw "Invalid haxe.Int64.compare Wasm native signature";
			var outputLocal = requiredLocal(values, output.id),
				leftLocal = requiredLocal(values, arguments[0].id),
				rightLocal = requiredLocal(values, arguments[1].id);
			body.push(LocalGet(leftLocal));
			body.push(LocalGet(rightLocal));
			body.push(I64LtS);
			body.push(If(null));
			body.push(I32Const(-1));
			body.push(LocalSet(outputLocal));
			body.push(Else);
			body.push(LocalGet(leftLocal));
			body.push(LocalGet(rightLocal));
			body.push(I64Eq);
			body.push(If(null));
			body.push(I32Const(0));
			body.push(LocalSet(outputLocal));
			body.push(Else);
			body.push(I32Const(1));
			body.push(LocalSet(outputLocal));
			body.push(End);
			body.push(End);
			return true;
		}
		if (name == "haxe.Int64.shl" || name == "haxe.Int64.shr" || name == "haxe.Int64.ushr") {
			if (arguments.length != 2 || output.type != I64)
				throw 'Invalid $name Wasm native signature';
			var valueLocal = requiredLocal(values, arguments[0].id),
				shiftLocal = requiredLocal(values, arguments[1].id),
				outputLocal = requiredLocal(values, output.id);
			body.push(LocalGet(shiftLocal));
			body.push(I32Const(0));
			body.push(I32LtS);
			body.push(LocalGet(shiftLocal));
			body.push(I32Const(64));
			body.push(I32LtS);
			body.push(I32Eqz);
			body.push(I32Or);
			body.push(If(null));
			if (name == "haxe.Int64.shr") {
				body.push(LocalGet(valueLocal));
				body.push(I64Const(0));
				body.push(I64LtS);
				body.push(If(null));
				body.push(I64Const(-1));
				body.push(LocalSet(outputLocal));
				body.push(Else);
				body.push(I64Const(0));
				body.push(LocalSet(outputLocal));
				body.push(End);
			} else {
				body.push(I64Const(0));
				body.push(LocalSet(outputLocal));
			}
			body.push(Else);
			body.push(LocalGet(valueLocal));
			body.push(LocalGet(shiftLocal));
			body.push(I64ExtendI32U);
			body.push(name == "haxe.Int64.shl" ? I64Shl : name == "haxe.Int64.shr" ? I64ShrS : I64ShrU);
			body.push(LocalSet(outputLocal));
			body.push(End);
			return true;
		}
		var operation = switch name {
			case "haxe.Int64.add": I64Add;
			case "haxe.Int64.sub": I64Sub;
			case "haxe.Int64.and": I64And;
			case "haxe.Int64.or": I64Or;
			case "haxe.Int64.xor": I64Xor;
			case _: null;
		};
		if (name == "haxe.Int64.make") {
			if (arguments.length != 2 || output.type != I64)
				throw "Invalid haxe.Int64.make Wasm native signature";
			body.push(LocalGet(requiredLocal(values, arguments[0].id)));
			body.push(I64ExtendI32S);
			body.push(I64Const(32));
			body.push(I64Shl);
			body.push(LocalGet(requiredLocal(values, arguments[1].id)));
			body.push(I64ExtendI32U);
			body.push(I64Or);
			body.push(LocalSet(requiredLocal(values, output.id)));
			return true;
		}
		if (operation == null)
			return false;
		if (arguments.length != 2 || output.type != I64)
			throw 'Invalid $name Wasm native signature';
		body.push(LocalGet(requiredLocal(values, arguments[0].id)));
		body.push(LocalGet(requiredLocal(values, arguments[1].id)));
		body.push(operation);
		body.push(LocalSet(requiredLocal(values, output.id)));
		return true;
	}

	static function nativeArgument(body:Array<WasmInstruction>, argument:IrValue, values:Map<Int, Int>, bytesDataPointer:Int):Void {
		body.push(LocalGet(requiredLocal(values, argument.id)));
		switch argument.type {
			case Bytes, ManagedBytes:
				body.push(Call(bytesDataPointer));
			case Abstract("realtime_bytes"):
				body.push(I32Const(WasmLayout.STRING_DATA_OFFSET));
				body.push(I32Add);
			case _:
		}
	}

	static function objectField(layout:WasmLayout, object:IrValue, fieldName:String):WasmFieldLayout
		return switch object.type {
			case Obj(name): layout.field(name, fieldName);
			default: throw 'Wasm field access requires an object reference, got ${Std.string(object.type)}';
		};

	static function arrayElement(array:IrValue):IrType
		return switch array.type {
			case Array(element): element;
			default: throw 'Wasm array access requires an Array reference, got ${Std.string(array.type)}';
		};

	static function load(type:IrType, offset:Int):WasmInstruction
		return switch type {
			case I64: I64Load(offset);
			case F64: F64Load(offset);
			default: I32Load(offset);
		};

	static function store(type:IrType, offset:Int):WasmInstruction
		return switch type {
			case I64: I64Store(offset);
			case F64: F64Store(offset);
			default: I32Store(offset);
		};

	static function virtualTargets(program:IrProgram, interfaceName:String, methodName:String, functions:Map<String, Int>):Array<{
		typeName:String,
		functionIndex:Int,
		argumentTypes:Array<IrType>,
		resultType:IrType
	}> {
		var result:Array<{
			typeName:String,
			functionIndex:Int,
			argumentTypes:Array<IrType>,
			resultType:IrType
		}> = [];
		for (object in program.objects) {
			if (!implementsInterface(program, object.name, interfaceName))
				continue;
			var functionName = findMethod(program, object.name, methodName);
			if (functionName != null) {
				var functionIndex = functions.get(functionName),
					targetFunction:Null<IrFunction> = null;
				for (candidate in program.functions)
					if (candidate.name == functionName)
						targetFunction = candidate;
				if (functionIndex != null) {
					if (targetFunction == null)
						throw 'Wasm interface target "$functionName" has no Haxe function signature';
					result.push({
						typeName: object.name,
						functionIndex: functionIndex,
						argumentTypes: [for (argument in targetFunction.arguments) argument.type],
						resultType: targetFunction.result
					});
				}
			}
		}
		result.sort(function(left, right) return objectInheritanceDepth(program, right.typeName) - objectInheritanceDepth(program, left.typeName));
		return result;
	}

	static function classVirtualTargets(program:IrProgram, staticType:String, methodName:String, functions:Map<String, Int>):Array<{
		typeName:String,
		functionIndex:Int,
		argumentTypes:Array<IrType>,
		resultType:IrType
	}> {
		var result:Array<{
			typeName:String,
			functionIndex:Int,
			argumentTypes:Array<IrType>,
			resultType:IrType
		}> = [];
		for (object in program.objects) {
			if (!isObjectSubtype(program, object.name, staticType))
				continue;
			var functionName = findMethod(program, object.name, methodName);
			if (functionName != null) {
				var functionIndex = functions.get(functionName),
					targetFunction:Null<IrFunction> = null;
				for (candidate in program.functions)
					if (candidate.name == functionName)
						targetFunction = candidate;
				if (functionIndex != null) {
					if (targetFunction == null)
						throw 'Wasm class target "$functionName" has no Haxe function signature';
					result.push({
						typeName: object.name,
						functionIndex: functionIndex,
						argumentTypes: [for (argument in targetFunction.arguments) argument.type],
						resultType: targetFunction.result
					});
				}
			}
		}
		result.sort(function(left, right) return objectInheritanceDepth(program, right.typeName) - objectInheritanceDepth(program, left.typeName));
		return result;
	}

	static function isObjectSubtype(program:IrProgram, actual:String, expected:String):Bool {
		if (actual == expected)
			return true;
		for (object in program.objects)
			if (object.name == actual)
				return object.base != null && isObjectSubtype(program, object.base, expected);
		return false;
	}

	static function objectInheritanceDepth(program:IrProgram, typeName:String):Int {
		for (object in program.objects)
			if (object.name == typeName)
				return object.base == null ? 0 : objectInheritanceDepth(program, object.base) + 1;
		return 0;
	}

	static function findMethod(program:IrProgram, objectName:String, methodName:String):Null<String> {
		for (object in program.objects)
			if (object.name == objectName) {
				for (method in object.methods)
					if (method.name == methodName)
						return method.functionName;
				return object.base == null ? null : findMethod(program, object.base, methodName);
			}
		return null;
	}

	static function implementsInterface(program:IrProgram, objectName:String, interfaceName:String):Bool {
		for (object in program.objects)
			if (object.name == objectName) {
				for (implemented in object.interfaces)
					if (interfaceExtends(program, implemented, interfaceName))
						return true;
				return object.base != null && implementsInterface(program, object.base, interfaceName);
			}
		return false;
	}

	static function interfaceExtends(program:IrProgram, actual:String, expected:String):Bool {
		if (actual == expected)
			return true;
		for (interfaceDecl in program.interfaces)
			if (interfaceDecl.name == actual)
				for (base in interfaceDecl.bases)
					if (interfaceExtends(program, base, expected))
						return true;
		return false;
	}

	public static function typeId(type:IrType):Int {
		var identity = switch type {
			case Iterator(_): Abstract("realtime_iterator");
			default: type;
		}, text = Std.string(identity), hash:Int = -2128831035;
		for (index in 0...text.length) {
			hash = Std.int(hash ^ text.charCodeAt(index));
			hash = Std.int(hash * 16777619);
		}
		return hash;
	}

	static function align(value:Int, boundary:Int):Int
		return (value + boundary - 1) & ~(boundary - 1);

	static function binary(body:Array<WasmInstruction>, output:IrValue, left:IrValue, right:IrValue, values:Map<Int, Int>, op:WasmInstruction):Void {
		emit(body, [
			LocalGet(requiredLocal(values, left.id)),
			LocalGet(requiredLocal(values, right.id)),
			op,
			LocalSet(requiredLocal(values, output.id))
		]);
	}

	static function shift(body:Array<WasmInstruction>, output:IrValue, left:IrValue, right:IrValue, values:Map<Int, Int>, op:WasmInstruction):Void {
		body.push(LocalGet(requiredLocal(values, left.id)));
		body.push(LocalGet(requiredLocal(values, right.id)));
		if (left.type == I64 && right.type == I32)
			body.push(I64ExtendI32U);
		body.push(op);
		body.push(LocalSet(requiredLocal(values, output.id)));
	}

	static function arithmeticInstruction(type:IrType, f64:WasmInstruction, i64:WasmInstruction, i32:WasmInstruction):WasmInstruction
		return switch type {
			case F64: f64;
			case I64: i64;
			default: i32;
		};

	static function comparisonInstruction(type:IrType, f64:WasmInstruction, i64:WasmInstruction, i32:WasmInstruction):WasmInstruction
		return switch type {
			case F64: f64;
			case I64: i64;
			default: i32;
		};

	static function rootPrologue(state:{
		frame:Int,
		top:Int,
		frameTop:Int,
		slots:Array<Int>,
		slotByValue:Map<Int, Int>,
		live:Map<Int, Map<Int, Array<Int>>>,
		size:Int
	}, rootLimit:Int):Array<WasmInstruction> {
		var result:Array<WasmInstruction> = [
			GlobalGet(state.top),
			I32Const(state.size),
			I32Add,
			I32Const(rootLimit),
			I32LeS,
			I32Eqz,
			If(null),
			Unreachable,
			End,
			GlobalGet(state.top),
			LocalTee(state.frame),
			GlobalGet(state.top),
			I32Store(WasmLayout.ROOT_PREVIOUS_TOP_OFFSET),
			LocalGet(state.frame),
			GlobalGet(state.frameTop),
			I32Store(WasmLayout.ROOT_PREVIOUS_FRAME_OFFSET),
			LocalGet(state.frame),
			I32Const(0),
			I32Store(WasmLayout.ROOT_COUNT_OFFSET),
			LocalGet(state.frame),
			I32Const(state.size),
			I32Add,
			GlobalSet(state.top),
			LocalGet(state.frame),
			GlobalSet(state.frameTop)
		];
		return result;
	}

	static function snapshotRoots(body:Array<WasmInstruction>, ?block:Int = -1, ?instruction:Int = -1):Void {
		var rootState = activeGcRootState;
		if (rootState == null || block < 0 || instruction < 0)
			return;
		var state = rootState;
		var blockLive = state.live.get(block);
		if (blockLive == null)
			return;
		var live = blockLive.get(instruction);
		if (live == null)
			return;
		body.push(LocalGet(state.frame));
		body.push(I32Const(live.length));
		body.push(I32Store(WasmLayout.ROOT_COUNT_OFFSET));
		for (denseIndex in 0...live.length) {
			var valueId = live[denseIndex];
			var index = state.slotByValue.get(valueId);
			if (index == null)
				continue;
			body.push(LocalGet(state.frame));
			body.push(I32Const(WasmLayout.ROOT_VALUES_OFFSET + denseIndex * 4));
			body.push(I32Add);
			body.push(LocalGet(state.slots[index]));
			body.push(I32Store(0));
		}
	}

	static function restoreRoots(body:Array<WasmInstruction>):Void {
		var rootState = activeGcRootState;
		if (rootState != null) {
			body.push(LocalGet(rootState.frame));
			body.push(I32Load(WasmLayout.ROOT_PREVIOUS_TOP_OFFSET));
			body.push(GlobalSet(rootState.top));
			body.push(LocalGet(rootState.frame));
			body.push(I32Load(WasmLayout.ROOT_PREVIOUS_FRAME_OFFSET));
			body.push(GlobalSet(rootState.frameTop));
		}
	}

	static function emit(body:Array<WasmInstruction>, instructions:Array<WasmInstruction>):Void
		for (instruction in instructions)
			body.push(instruction);

	static function outputOf(instruction:IrInstruction):Null<IrValue>
		return switch instruction {
			case Phi(output, _), ConstVoid(output), ConstInt(output, _), ConstFloat(output, _), ConstString(output, _), StaticDataAddress(output, _),
				ConstBool(output, _), ConstNull(output), TypeValue(output, _), ToDyn(output, _), IntToFloat(output, _), IntToInt64(output, _),
				FloatToInt(output, _), SafeCast(output, _), Catch(output), GlobalGet(output, _), Add(output, _, _), Sub(output, _, _), Mul(output, _, _),
				Div(output, _, _), Mod(output, _, _), BitAnd(output, _, _), BitXor(output, _, _), BitOr(output, _, _), ShiftLeft(output, _, _),
				ShiftRight(output, _, _), UnsignedShiftRight(output, _, _), Less(output, _, _), LessEqual(output, _, _), Equal(output, _, _),
				Call(output, _, _), CNativeCall(output, _, _), StaticClosure(output, _), InstanceClosure(output, _, _), CallClosure(output, _, _),
				ToVirtual(output, _), MethodCall(output, _, _, _), NewObject(output, _), FieldGet(output, _, _), ArrayGet(output, _, _), ArraySize(output, _),
				IteratorNew(output, _), IteratorHasNext(output, _), IteratorNext(output, _), MakeEnum(output, _, _, _), EnumIndex(output, _),
				EnumField(output, _, _, _): output;
			case BeginTry(_, _), EndTry(_), GlobalSet(_, _), FieldSet(_, _, _), ArraySet(_, _, _): null;
		};
}
