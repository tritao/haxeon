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
import compiler.backend.wasm.WasmRepresentation.WasmRepresentation;
import compiler.backend.wasm.WasmRepresentation.WasmLinearRepresentation;
import compiler.backend.wasm.WasmRepresentation.WasmGcRepresentation;
import compiler.backend.wasm.WasmGcMaps;

private typedef WasmClosureTypes = {
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
		if (target.referenceModel != Linear32)
			throw 'Wasm backend target ${options.target} is not implemented yet';
		IrVerifier.verify(program);
		var module = new WasmModule(target.debugNames ? "haxeon" : null),
			importMemory = options.importMemory == true,
			contract = options.memoryContract,
			memoryBase = contract == null ? (options.memoryBase == null ? 0 : options.memoryBase) : contract.guestBase,
			exportedFunctions = options.exports == null ? [] : options.exports;
		if (contract != null) {
			if (!importMemory)
				throw "A Wasm memory contract requires imported memory";
			MemoryContractCodec.validate(contract);
		}
		if (memoryBase < 0 || (memoryBase & 7) != 0)
			throw 'Wasm memory base must be a non-negative 8-byte-aligned value, got $memoryBase';
		module.importMemory = importMemory;
		var preferredEntry = hasFunction(program, "main") ? "main" : hasFunction(program, "Main.main") ? "Main.main" : program.entryPoint,
			roots = exportedFunctions.copy();
		if (hasFunction(program, "__init"))
			roots.push("__init");
		var reachable = reachableFunctions(program, preferredEntry, roots);
		var usedCNatives = reachableCNatives(program, reachable),
			usedNatives = reachableNatives(program, reachable);
		var layout = new WasmLayout(program);
		var strings:Map<String, Int> = [],
			nextData = memoryBase + WasmLayout.STRING_DATA_OFFSET;
		for (fn in program.functions)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case ConstString(_, value):
							if (!strings.exists(value)) {
								var bytes = stringBytes(value);
								var offset = nextData;
								module.data.push({offset: offset, bytes: bytes});
								strings.set(value, offset);
								nextData = align(offset + bytes.length, 8);
							}
						default:
					}
		for (value in ["null", "true", "false", "NaN", "Infinity", "-Infinity", "0"])
			if (!strings.exists(value)) {
				var bytes = stringBytes(value), offset = nextData;
				module.data.push({offset: offset, bytes: bytes});
				strings.set(value, offset);
				nextData = align(offset + bytes.length, 8);
			}
		var ryuTableBase = -1;
		if (usedNatives.exists("__std_string")) {
			var ryuTable = WasmRyuTables.bytes();
			ryuTableBase = nextData;
			module.data.push({offset: nextData, bytes: ryuTable});
			nextData = align(nextData + ryuTable.length, 8);
		}
		module.memoryMin = 1;
		module.exportMemory = !importMemory;
		var rootBase = align(Std.int(Math.max(1024, nextData)), 8),
			rootReserve = WasmLayout.ROOT_RESERVE,
			rootLimit = rootBase + rootReserve,
			heapStart = rootLimit;
		if (contract != null && heapStart > contract.guestLimit)
			throw 'Wasm guest layout exceeds memory contract guest limit ${contract.guestLimit}';
		module.memoryMin = contract == null ? memoryPages(heapStart) : memoryPages(contract.memorySize);
		var heapTop = module.globals.length;
		module.globals.push({type: I32, mutable: true, init: [I32Const(heapStart)]});
		var rootTop = module.globals.length;
		module.globals.push({type: I32, mutable: true, init: [I32Const(rootBase)]});
		var rootFrameTop = module.globals.length;
		module.globals.push({type: I32, mutable: true, init: [I32Const(0)]});
		var freeHead = module.globals.length;
		module.globals.push({type: I32, mutable: true, init: [I32Const(0)]});
		var markStackTop = module.globals.length;
		module.globals.push({type: I32, mutable: true, init: [I32Const(0)]});
		var gcBudget = -1;
		if (options.wasmGcStress != true) {
			gcBudget = module.globals.length;
			module.globals.push({type: I32, mutable: true, init: [I32Const(WasmLayout.GC_MIN_ALLOCATION_BUDGET)]});
		}
		var allocationCount = -1, allocationBytes = -1, largestAllocation = -1, collectionCount = -1;
		if (options.wasmMemoryStats == true) {
			allocationCount = module.globals.length;
			module.globals.push({type: I32, mutable: true, init: [I32Const(0)]});
			allocationBytes = module.globals.length;
			module.globals.push({type: I32, mutable: true, init: [I32Const(0)]});
			largestAllocation = module.globals.length;
			module.globals.push({type: I32, mutable: true, init: [I32Const(0)]});
			collectionCount = module.globals.length;
			module.globals.push({type: I32, mutable: true, init: [I32Const(0)]});
		}
		var globals:Map<String, Int> = [];
		var rootGlobals:Array<Int> = [];
		for (field in program.staticFields) {
			globals.set(field.name, module.globals.length);
			module.globals.push({type: requireValueType(field.type), mutable: true, init: zeroValue(field.type)});
			if (WasmTarget.isReference(field.type))
				rootGlobals.push(requiredGlobal(globals, field.name));
		}
		var functions:Map<String, Int> = [];
		addCNativeImports(module, functions, program, usedCNatives);
		addRuntimeImports(module, program, usedNatives);
		var mark = addGcMark(module, heapStart, heapTop, markStackTop);
		var trace = addGcTrace(module, program, layout, mark);
		var collector = addGcCollector(module, heapStart, heapTop, rootFrameTop, freeHead, mark, trace, markStackTop, rootGlobals, collectionCount);
		var allocator = addAllocator(module, collector, heapStart, heapTop, freeHead, gcBudget, options.wasmGcStress == true, allocationCount,
			allocationBytes, largestAllocation);
		functions.set("__haxeon_alloc", allocator);
		addRuntimeFunctions(module, functions, program, allocator, strings, ryuTableBase);
		for (native in program.natives) {
			var stride = arrayStrideForNative(native.name);
			if (stride != null)
				functions.set(native.name, addArrayAllocator(module, native.name, stride, allocator));
		}
		var runtimeFunctionCount = module.functions.length;
		var methods:Map<String, String> = [];
		for (object in program.objects)
			for (method in object.methods)
				methods.set(object.name + "." + method.name, method.functionName);
		for (fn in program.functions) {
			if (!reachable.exists(fn.name))
				continue;
			if (fn.name == "__entry" && preferredEntry != "__entry")
				continue;
			var parameters:Array<WasmValueType> = [];
			for (argument in fn.arguments)
				try
					parameters.push(requireValueType(argument.type))
				catch (error:Dynamic)
					throw 'Wasm function ${fn.name} has an unsupported parameter type: $error';
			var results:Array<WasmValueType> = [];
			try
				results = resultTypes(fn.result)
			catch (error:Dynamic)
				throw 'Wasm function ${fn.name} has an unsupported result type: $error';
			var type:WasmFunctionType = {parameters: parameters, results: results};
			functions.set(fn.name, module.addFunction(new WasmFunction(fn.name, type)));
		}
		var closureTypes = collectClosureTypes(module, program),
			representation:WasmRepresentation = new WasmLinearRepresentation(layout, allocator),
			tableSlots = buildTableSlots(module, functions),
			exceptionTagType:Null<Int> = hasExceptions(program) ? module.typeIndex({
				parameters: [I32],
				results: []
			}) : null, // The module declares one tag; instruction immediates use its tag index, not this type index.
			exceptionTag:Null<Int> = exceptionTagType == null ? null : 0;
		module.exceptionTagType = exceptionTagType;
		wrapRuntimeFunctions(module, runtimeFunctionCount, rootTop, rootFrameTop, rootLimit, exceptionTag);
		module.exportTable = module.tableMin != null;
		var gcRootMetadata = WasmGcRoots.encodeAndVisit(program, function(fn, rootPoints) {
			if (!reachable.exists(fn.name) || (fn.name == "__entry" && preferredEntry != "__entry"))
				return;
			var functionIndex = requiredFunctionIndex(functions, fn.name);
			module.setFunction(functionIndex,
				WasmFunctionLower.lower(fn, functions, module.functionType(functionIndex), layout, allocator, rootTop, rootFrameTop, rootLimit, globals,
					strings, methods, closureTypes, tableSlots, exceptionTag, rootPoints, program, representation));
		});
		module.customSections.push({name: "haxeon.gc.roots", bytes: gcRootMetadata});
		module.customSections.push({name: "haxeon.patch", bytes: WasmPatch.manifest(program, patchChanged)});
		module.customSections.push({name: "haxeon.patch.slots", bytes: WasmPatch.tableManifest(tableSlots)});
		if (contract != null)
			module.customSections.push({name: MemoryContractCodec.SECTION_NAME, bytes: MemoryContractCodec.encode(contract)});
		var entry = functions.get(preferredEntry);
		if (entry == null)
			throw 'Wasm entry point $preferredEntry was not emitted';
		if (hasFunction(program, "__init"))
			module.start = functions.get("__init");
		module.exports.push({name: "main", functionIndex: entry});
		for (exported in exportedFunctions) {
			var exportIndex = functions.get(exported);
			if (exportIndex == null)
				throw 'Wasm export "$exported" is not a reachable function';
			module.exports.push({name: exported, functionIndex: exportIndex});
		}
		if (options.wasmMemoryStats == true) {
			addMemoryStatExport(module, "haxeon.memory.heap_base", [I32Const(heapStart)]);
			addMemoryStatExport(module, "haxeon.memory.heap_top", [GlobalGet(heapTop)]);
			addMemoryStatExport(module, "haxeon.memory.root_base", [I32Const(rootBase)]);
			addMemoryStatExport(module, "haxeon.memory.root_top", [GlobalGet(rootTop)]);
			addMemoryStatExport(module, "haxeon.memory.root_limit", [I32Const(rootLimit)]);
			// Kept temporarily for hosts that still display the old metadata counters.
			// In-block headers make out-of-line GC metadata a zero-sized region.
			addMemoryStatExport(module, "haxeon.memory.metadata_base", [I32Const(heapStart)]);
			addMemoryStatExport(module, "haxeon.memory.metadata_top", [I32Const(heapStart)]);
			addMemoryStatExport(module, "haxeon.memory.allocation_count", [GlobalGet(allocationCount)]);
			addMemoryStatExport(module, "haxeon.memory.allocated_bytes", [GlobalGet(allocationBytes)]);
			addMemoryStatExport(module, "haxeon.memory.largest_allocation_bytes", [GlobalGet(largestAllocation)]);
			addMemoryStatExport(module, "haxeon.memory.collection_count", [GlobalGet(collectionCount)]);
		}
		return {target: options.target, bytes: WasmEncoder.encode(module)};
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
				if (native.result == ManagedBytes && native.pointerLength != null)
					requiresLinearMemory = true;
				for (mode in native.argumentModes)
					switch mode {
						case BytesInput(_) | BytesInputOutput(_) | BytesOutput(_) | BytesSize:
							requiresScratchMemory = true;
						case Value | Output | InputOutput:
					}
			}

		var plan = new WasmGcTypePlan(program),
			gcRepresentation = new WasmGcRepresentation(plan),
			representation:WasmRepresentation = gcRepresentation,
			module = new WasmModule(options.debugNames ? "haxeon" : null),
			globals:Map<String, Int> = [],
			functions:Map<String, Int> = [],
			methods:Map<String, String> = [];
		plan.addTo(module);
		var scratchTop = -1;
		if (requiresScratchMemory || requiresLinearMemory) {
			module.memoryMin = 1;
			module.exportMemory = true;
		}
		if (requiresScratchMemory) {
			scratchTop = module.globals.length;
			module.globals.push({type: I32, mutable: true, init: [I32Const(8)]});
		}
		addGcCNativeImports(module, functions, program, usedCNatives);
		addGcMapRuntimeFunctions(module, functions, plan, program, usedNatives);
		addGcRuntimeNativeFunctions(module, functions, plan, representation, program, usedNatives);
		addGcMapProjectionFunctions(module, functions, plan, program, reachable);
		if (requiresScratchMemory) {
			var scratchAllocator = addGcScratchAllocator(module, scratchTop);
			gcRepresentation.configureCNativeScratch(scratchTop, scratchAllocator);
		}
		var exceptionTagType:Null<Int> = hasExceptions(program) ? module.typeIndex({parameters: [representation.valueType(Dyn)], results: []}) : null,
			exceptionTag:Null<Int> = exceptionTagType == null ? null : 0;
		module.exceptionTagType = exceptionTagType;
		for (field in program.staticFields) {
			globals.set(field.name, module.globals.length);
			module.globals.push({type: representation.valueType(field.type), mutable: true, init: representation.zeroValue(field.type)});
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
			if (usedNatives.exists(native.name) && !isSupportedGcNative(program, native.name))
				throw 'Wasm GC lowering does not support runtime native "${native.name}" yet';
		for (native in program.cNatives)
			if (usedCNatives.exists(native.name)) {
				if (directCNatives.exists(native.name) && isGcPointerRelease(program, native))
					throw 'Wasm GC native release function "${native.name}" is callable only as owned byte-result cleanup';
				if (isGcPointerRelease(program, native))
					validateGcPointerReleaseImport(native);
				else
					validateGcCNative(native);
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
						case ConstString(_, _):
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

	static function addGcRuntimeNativeFunctions(module:WasmModule, functions:Map<String, Int>, plan:WasmGcTypePlan, representation:WasmRepresentation,
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
				representation.beginFunction(allocateLocal, null);
				var arguments = [
					for (index in 0...native.arguments.length)
						new IrValue(index, native.name + "_argument_" + index, native.arguments[index])
				], result = new IrValue(-1, native.name + "_result", native.result), resultLocal = allocateLocal(plan.valueType(native.result)),
					body = representation.lowerRuntimeCall(native.name, result, arguments, resultLocal, [for (index in 0...arguments.length) index]);
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
				"__exception_matches", "__reflect_is_object", "__dynamic_equal", "__bytes_alloc", "__bytes_of_string", "__bytes_length", "__bytes_get",
				"__bytes_set", "__bytes_get_i32", "__bytes_set_i32", "getI32", "setI32", "__bytes_view", "__bytes_sub", "__bytes_compare",
				"__bytes_to_string", "__bytes_get_string", "structSlice", "__bytes_input_new", "__bytes_input_position", "__bytes_input_big_endian",
				"__bytes_input_set_big_endian", "__bytes_input_read_byte", "__bytes_input_read_i32", "__bytes_input_read_f64", "__bytes_input_read_string",
				"__bytes_input_read", "__bytes_output_new", "__bytes_output_big_endian", "__bytes_output_set_big_endian", "__bytes_output_write_byte",
				"__bytes_output_write_i32", "__bytes_output_write_f64", "__bytes_output_write_string", "__bytes_output_write", "__bytes_output_write_range",
				"__bytes_output_get_bytes", "__string_length", "__string_char_at", "__string_char_code_at", "__string_concat", "__string_equal",
				"__string_compare_full", "__string_index_of", "__string_index_of_from", "__string_last_index_of", "__string_last_index_of_from",
				"__string_to_lower_case", "__string_to_upper_case", "__string_split", "__string_substring": true;
			default: false;
		};
	}

	static function validateGcCNative(native:IrCNative):Void {
		if (native.argumentModes.length != native.arguments.length)
			throw 'Wasm GC C native "${native.name}" has invalid argument ABI metadata';
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
				case Output | InputOutput:
					throw 'Wasm GC C native "${native.name}" supports byte slices and HXI output buffers only so far';
			}
		switch native.result {
			case Void:
			case I32, Bool, I64, F64:
				gcCNativeValueType(native.result);
			case ManagedBytes if (native.pointerLength != null):
				if (native.pointerOwnership != "borrowed" && native.pointerOwnership != "owned")
					throw 'Wasm GC C native "${native.name}" requires borrowed or owned pointer metadata';
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

	static function gcCNativeValueType(type:IrType):WasmValueType
		return switch type {
			case I32, Bool: I32;
			case I64: I64;
			case F64: F64;
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
						case BytesInput(_) | BytesInputOutput(_) | BytesOutput(_) | BytesSize: I32;
						case Value: gcCNativeValueType(native.arguments[index]);
						case _: throw 'Wasm GC C native "${native.name}" has unsupported argument direction';
					});
			var type:WasmFunctionType = {
				parameters: parameters,
				results: switch native.result {
					case Void: [];
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
		var body:Array<WasmInstruction> = [
			GlobalGet(scratchTop),
			LocalTee(1),
			LocalGet(0),
			I32Add,
			LocalTee(2),
			GlobalSet(scratchTop),
			LocalGet(2),
			I32Const(65535),
			I32Add,
			I32Const(16),
			I32ShrU,
			LocalSet(3),
			MemorySize,
			LocalSet(4),
			LocalGet(4),
			LocalGet(3),
			I32LtS,
			If(null),
			LocalGet(3),
			LocalGet(4),
			I32Sub,
			MemoryGrow,
			I32Const(-1),
			I32Eq,
			If(null),
			Unreachable,
			End,
			End,
			LocalGet(1),
			Return
		];
		var type:WasmFunctionType = {parameters: [I32], results: [I32]};
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

	static function addMemoryStatExport(module:WasmModule, name:String, body:Array<WasmInstruction>):Void {
		var index = module.addFunction(new WasmFunction(name, {parameters: [], results: [I32]}, [], body));
		module.exports.push({name: name, functionIndex: index});
	}

	static function addCNativeImports(module:WasmModule, functions:Map<String, Int>, program:IrProgram, used:Map<String, Bool>):Void {
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

	static function addRuntimeImports(module:WasmModule, program:IrProgram, used:Map<String, Bool>):Void {
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

	static function reachableNatives(program:IrProgram, reachable:Map<String, Bool>):Map<String, Bool> {
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

	static function reachableCNatives(program:IrProgram, reachable:Map<String, Bool>):Map<String, Bool> {
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
			if (result.exists(native.name) && native.result == ManagedBytes && native.pointerLength != null) {
				result.set(requiredCNativeBySymbol(program, native.pointerLength).name, true);
				if (native.pointerOwnership == "owned" && native.pointerRelease != null)
					result.set(requiredCNativeBySymbol(program, native.pointerRelease).name, true);
			}
		return result;
	}

	static function isGcPointerRelease(program:IrProgram, candidate:IrCNative):Bool {
		for (native in program.cNatives)
			if (native.result == ManagedBytes
				&& native.pointerLength != null
				&& native.pointerOwnership == "owned"
				&& native.pointerRelease == candidate.symbol)
				return true;
		return false;
	}

	static function requiredCNativeBySymbol(program:IrProgram, symbol:String):IrCNative {
		for (native in program.cNatives)
			if (native.symbol == symbol)
				return native;
		throw 'Wasm GC byte result references missing length import "$symbol"';
	}

	static function memoryPages(bytes:Int):Int
		return Std.int(Math.ceil(bytes / 65536.0));

	static function wrapRuntimeFunctions(module:WasmModule, count:Int, rootTop:Int, rootFrameTop:Int, rootLimit:Int, exceptionTag:Null<Int>):Void {
		for (index in 0...count) {
			var fn = module.functions[index];
			if (fn.name == "__haxeon_gc_mark" || fn.name == "__haxeon_gc_trace" || fn.name == "__haxeon_gc_collect")
				continue;
			module.setFunction(module.imports.length + index, wrapRuntimeFunction(fn, rootTop, rootFrameTop, rootLimit, exceptionTag));
		}
	}

	static function wrapRuntimeFunction(fn:WasmFunction, rootTop:Int, rootFrameTop:Int, rootLimit:Int, exceptionTag:Null<Int>):WasmFunction {
		var rootSlots:Array<Int> = [];
		for (index in 0...fn.type.parameters.length)
			if (fn.type.parameters[index] == I32)
				rootSlots.push(index);
		for (index in 0...fn.locals.length)
			if (fn.locals[index].type == I32)
				rootSlots.push(fn.type.parameters.length + index);
		if (rootSlots.length == 0)
			return fn;
		var frame = fn.type.parameters.length + fn.locals.length,
			locals = fn.locals.copy(),
			exceptionLocal = frame + 1;
		locals.push({type: I32});
		if (exceptionTag != null)
			locals.push({type: I32});
		var frameSize = align(12 + rootSlots.length * 4, 8),
			body:Array<WasmInstruction> = [
				GlobalGet(rootTop),
				I32Const(frameSize),
				I32Add,
				I32Const(rootLimit),
				I32LeS,
				I32Eqz,
				If(null),
				Unreachable,
				End,
				GlobalGet(rootTop),
				LocalTee(frame),
				GlobalGet(rootTop),
				I32Store(WasmLayout.ROOT_PREVIOUS_TOP_OFFSET),
				LocalGet(frame),
				GlobalGet(rootFrameTop),
				I32Store(WasmLayout.ROOT_PREVIOUS_FRAME_OFFSET),
				LocalGet(frame),
				I32Const(rootSlots.length),
				I32Store(WasmLayout.ROOT_COUNT_OFFSET),
				LocalGet(frame),
				I32Const(frameSize),
				I32Add,
				GlobalSet(rootTop),
				LocalGet(frame),
				GlobalSet(rootFrameTop)
			];
		for (instruction in fn.body) {
			if (isRuntimeCall(instruction))
				appendRuntimeRootSnapshot(body, frame, rootSlots);
			if (instruction == Return) {
				emitRuntimeRootFrameRestore(body, frame, rootTop, rootFrameTop);
			}
			body.push(instruction);
			if (isRuntimeLocalWrite(instruction))
				appendRuntimeRootSnapshot(body, frame, rootSlots);
		}
		// Runtime helpers often use Wasm's implicit void return instead of an
		// explicit Return instruction. Balance their shadow-root frame on that
		// normal fallthrough path as well; otherwise each helper call permanently
		// consumes root-stack space until a later call traps at rootLimit.
		if (fn.body.length == 0 || fn.body[fn.body.length - 1] != Return)
			emitRuntimeRootFrameRestore(body, frame, rootTop, rootFrameTop);
		if (exceptionTag != null) {
			var protectedBody:Array<WasmInstruction> = [Try(null)];
			protectedBody = protectedBody.concat(body);
			protectedBody.push(Catch(exceptionTag));
			protectedBody.push(LocalSet(exceptionLocal));
			emitRuntimeRootFrameRestore(protectedBody, frame, rootTop, rootFrameTop);
			protectedBody = protectedBody.concat([LocalGet(exceptionLocal), Throw(exceptionTag), End]);
			// Result-bearing runtime helpers terminate with explicit Return
			// instructions. Keep the unreachable marker for validation of those
			// result paths; void helpers may complete via implicit fallthrough.
			if (fn.type.results.length != 0)
				protectedBody.push(Unreachable);
			body = protectedBody;
		}
		return new WasmFunction(fn.name, fn.type, locals, body);
	}

	static function emitRuntimeRootFrameRestore(body:Array<WasmInstruction>, frame:Int, rootTop:Int, rootFrameTop:Int):Void {
		body.push(LocalGet(frame));
		body.push(I32Load(WasmLayout.ROOT_PREVIOUS_TOP_OFFSET));
		body.push(GlobalSet(rootTop));
		body.push(LocalGet(frame));
		body.push(I32Load(WasmLayout.ROOT_PREVIOUS_FRAME_OFFSET));
		body.push(GlobalSet(rootFrameTop));
	}

	static function isRuntimeCall(instruction:WasmInstruction):Bool
		return switch instruction {
			case Call(_): true;
			default: false;
		};

	static function isRuntimeLocalWrite(instruction:WasmInstruction):Bool
		return switch instruction {
			case LocalSet(_), LocalTee(_): true;
			default: false;
		};

	static function appendRuntimeRootSnapshot(body:Array<WasmInstruction>, frame:Int, slots:Array<Int>):Void {
		for (index in 0...slots.length) {
			body.push(LocalGet(frame));
			body.push(I32Const(WasmLayout.ROOT_VALUES_OFFSET + index * 4));
			body.push(I32Add);
			body.push(LocalGet(slots[index]));
			body.push(I32Store(0));
		}
	}

	static function appendRuntime(body:Array<WasmInstruction>, instructions:Array<WasmInstruction>):Void
		for (instruction in instructions)
			body.push(instruction);

	static function addRuntimeFunctions(module:WasmModule, functions:Map<String, Int>, program:IrProgram, allocator:Int,
			strings:Map<String, Int>, ryuTableBase:Int):Void {
		for (native in program.natives) {
			var runtimeFunction = addRuntimeNativeFunction(module, native, allocator);
			if (runtimeFunction != null)
				functions.set(native.name, runtimeFunction);
			else {
				var mapParts = mapNativeParts(native.name);
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
							functions.set(native.name, addArrayCopy(module, native.name, 4, allocator));
						case "__array_copy_f64":
							functions.set(native.name, addArrayCopy(module, native.name, 8, allocator));
						case "__array_index_of_i32", "__array_index_of_bool", "__array_index_of_ref":
							functions.set(native.name, addArrayIndexOf(module, native.name, 4, I32, null));
						case "__array_index_of_bytes":
							var stringEqual = functions.get("__string_equal");
							if (stringEqual == null) {
								stringEqual = addStringEqual(module, "__string_equal");
								functions.set("__string_equal", stringEqual);
							}
							functions.set(native.name, addArrayIndexOf(module, native.name, 4, I32, stringEqual));
						case "__array_index_of_f64":
							functions.set(native.name, addArrayIndexOf(module, native.name, 8, F64, null));
						case "__array_slice_i32", "__array_slice_bool", "__array_slice_ref", "__array_slice_bytes":
							functions.set(native.name, addArraySlice(module, native.name, 4, allocator));
						case "__array_slice_f64":
							functions.set(native.name, addArraySlice(module, native.name, 8, allocator));
						case "__array_join_bytes":
							var stringConcat = functions.get("__string_concat");
							if (stringConcat == null) {
								stringConcat = addStringConcat(module, "__string_concat", allocator);
								functions.set("__string_concat", stringConcat);
							}
							functions.set(native.name, addArrayJoinBytes(module, native.name, allocator, stringConcat));
						case "__array_concat_i32", "__array_concat_bool", "__array_concat_ref", "__array_concat_bytes":
							functions.set(native.name, addArrayConcat(module, native.name, 4, allocator));
						case "__array_concat_f64":
							functions.set(native.name, addArrayConcat(module, native.name, 8, allocator));
						case "__array_push_i32", "__array_push_bool", "__array_push_ref", "__array_push_bytes":
							functions.set(native.name, addArrayPush(module, native.name, 4, I32, allocator));
						case "__array_push_f64":
							functions.set(native.name, addArrayPush(module, native.name, 8, F64, allocator));
						case "__array_pop_i32", "__array_pop_bool", "__array_pop_ref", "__array_pop_bytes":
							functions.set(native.name, addArrayPop(module, native.name, 4, I32));
						case "__array_pop_f64":
							functions.set(native.name, addArrayPop(module, native.name, 8, F64));
						case "__array_unshift_i32", "__array_unshift_bool", "__array_unshift_ref", "__array_unshift_bytes":
							functions.set(native.name, addArrayUnshift(module, native.name, 4, I32, allocator));
						case "__array_unshift_f64":
							functions.set(native.name, addArrayUnshift(module, native.name, 8, F64, allocator));
						case "__array_insert_i32", "__array_insert_bool", "__array_insert_ref", "__array_insert_bytes":
							functions.set(native.name, addArrayInsert(module, native.name, 4, I32, allocator));
						case "__array_insert_f64":
							functions.set(native.name, addArrayInsert(module, native.name, 8, F64, allocator));
						case "__array_shift_i32", "__array_shift_bool", "__array_shift_ref", "__array_shift_bytes":
							functions.set(native.name, addArrayShift(module, native.name, 4, I32));
						case "__array_shift_f64":
							functions.set(native.name, addArrayShift(module, native.name, 8, F64));
						case "__array_resize_i32", "__array_resize_bool", "__array_resize_ref", "__array_resize_bytes":
							functions.set(native.name, addArrayResize(module, native.name, 4, I32, allocator));
						case "__array_resize_f64":
							functions.set(native.name, addArrayResize(module, native.name, 8, F64, allocator));
						case "__array_remove_i32", "__array_remove_bool", "__array_remove_ref":
							functions.set(native.name, addArrayRemove(module, native.name, 4, I32, null));
						case "__array_remove_bytes":
							var stringEqual = functions.get("__string_equal");
							if (stringEqual == null) {
								stringEqual = addStringEqual(module, "__string_equal");
								functions.set("__string_equal", stringEqual);
							}
							functions.set(native.name, addArrayRemove(module, native.name, 4, I32, stringEqual));
						case "__array_remove_f64":
							functions.set(native.name, addArrayRemove(module, native.name, 8, F64, null));
						case "__array_reverse_i32", "__array_reverse_bool", "__array_reverse_ref", "__array_reverse_bytes":
							functions.set(native.name, addArrayReverse(module, native.name, 4, I32));
						case "__array_reverse_f64":
							functions.set(native.name, addArrayReverse(module, native.name, 8, F64));
						case "__array_splice_i32", "__array_splice_bool", "__array_splice_ref", "__array_splice_bytes":
							functions.set(native.name, addArraySplice(module, native.name, 4, allocator));
						case "__array_splice_f64":
							functions.set(native.name, addArraySplice(module, native.name, 8, allocator));
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

	static function runtimeImport(module:WasmModule, native:compiler.ir.Ir.IrNative):Int {
		var existing = runtimeImportIndex(module, native);
		if (existing != null)
			return existing;
		var importModule = native.library == null || native.library == "" ? "env" : native.library,
			importName = native.symbol == null || native.symbol == "" ? native.name : native.symbol;
		return module.addImport(importModule, importName,
			{parameters: [for (argument in native.arguments) requireValueType(argument)], results: resultTypes(native.result)});
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

	static function addBytesAlloc(module:WasmModule, name:String, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: [I32]}, [{type: I32}], [
			LocalGet(0),
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			I32Add,
			Call(allocator),
			LocalSet(1),
			LocalGet(1),
			I32Const(typeId(Bytes)),
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
			I32Const(typeId(Bytes)),
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
			I32Const(typeId(Bytes)),
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
			I32Const(typeId(Bytes)),
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
			I32Const(typeId(Bytes)),
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
			I32Const(typeId(Bytes)),
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

	static function mapKeyType(mapName:String):IrType
		return StringTools.startsWith(mapName, "map_string_") ? Bytes : I32;

	static function mapValueType(mapName:String):IrType
		return if (StringTools.endsWith(mapName,
			"_i32")) I32; else if (StringTools.endsWith(mapName,
			"_bool")) Bool; else if (StringTools.endsWith(mapName,
			"_f64")) F64; else if (StringTools.endsWith(mapName,
			"_bytes")) Bytes; else if (StringTools.endsWith(mapName, "_ref")) Dyn; else throw 'Unknown Wasm map value ABI "$mapName"';

	static function mapEntrySize(valueType:IrType):Int
		return valueType == F64 ? 16 : 8;

	static function mapValueOffset(valueType:IrType):Int
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
			result = addArrayAllocator(module, name, valueType == F64 ? 8 : 4, allocator);
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
			I32Const(typeId(Abstract(mapName))),
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

	static function append(body:Array<WasmInstruction>, instructions:Array<WasmInstruction>):Void
		for (instruction in instructions)
			body.push(instruction);

	static function appendGcContainerOwner(body:Array<WasmInstruction>, backing:Int, owner:Int):Void {
		append(body, [
			LocalGet(backing),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Sub,
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			LocalGet(owner),
			I32Store(0)
		]);
	}

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
		return module.addFunction(new WasmFunction(name, {parameters: [I32, requireValueType(keyType)], results: [I32]}, [{type: I32}, {type: I32}], body));
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
		return module.addFunction(new WasmFunction(name, {parameters: [I32, requireValueType(keyType), requireValueType(valueType)], results: []},
			[{type: I32}, {type: I32}, {type: I32}, {type: I32}, {type: I32}, {type: I32}], body));
	}

	static function addMapExists(module:WasmModule, name:String, keyType:IrType, valueType:IrType, stringEqual:Int, find:Int):Int
		return module.addFunction(new WasmFunction(name, {parameters: [I32, requireValueType(keyType)], results: [I32]}, [],
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
				I32Const(typeId(valueType)),
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
				I32Const(typeId(F64)),
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
		return module.addFunction(new WasmFunction(name, {parameters: [I32, requireValueType(keyType)], results: [I32]},
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
		return module.addFunction(new WasmFunction(name, {parameters: [I32, requireValueType(keyType)], results: [I32]},
			[{type: I32}, {type: I32}, {type: I32}, {type: I32}], body));
	}

	static function addMapClear(module:WasmModule, name:String):Int
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: []}, [],
			[LocalGet(0), I32Const(0), I32Store(WasmLayout.MAP_COUNT_OFFSET)]));

	static function addMapSize(module:WasmModule, name:String):Int
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: [I32]}, [], [LocalGet(0), I32Load(WasmLayout.MAP_COUNT_OFFSET), Return]));

	static function collectClosureTypes(module:WasmModule, program:IrProgram):Map<String, WasmClosureTypes> {
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

	static function buildTableSlots(module:WasmModule, functions:Map<String, Int>):Map<String, Int> {
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
			I32Const(typeId(I32)),
			I32Eq,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			Return,
			End,
			LocalGet(0),
			I32Load(0),
			I32Const(typeId(Bool)),
			I32Eq,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			Return,
			End,
			LocalGet(0),
			I32Load(0),
			I32Const(typeId(F64)),
			I32Eq,
			If(null),
			LocalGet(0),
			F64Load(WasmLayout.DYN_PAYLOAD_OFFSET),
			I32TruncF64S,
			Return,
			End,
			LocalGet(0),
			I32Load(0),
			I32Const(typeId(I64)),
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
			body.push(I32Const(typeId(Obj(object.name))));
			body.push(I32Eq);
			body.push(If(null));
			body.push(I32Const(1));
			body.push(Return);
			body.push(End);
		}
		for (enumDecl in program.enums) {
			body.push(LocalGet(0));
			body.push(I32Const(typeId(Enum(enumDecl.name))));
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
			I32Const(typeId(I32)),
			I32Eq,
			If(null),
			I32Const(0),
			Return,
			End,
			LocalGet(0),
			I32Load(0),
			I32Const(typeId(Bool)),
			I32Eq,
			If(null),
			I32Const(0),
			Return,
			End,
			LocalGet(0),
			I32Load(0),
			I32Const(typeId(I64)),
			I32Eq,
			If(null),
			I32Const(0),
			Return,
			End,
			LocalGet(0),
			I32Load(0),
			I32Const(typeId(F64)),
			I32Eq,
			If(null),
			I32Const(0),
			Return,
			End,
			LocalGet(0),
			I32Load(0),
			I32Const(typeId(Bytes)),
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
			var accepted = [typeId(Obj(object.name))];
			var base = object.base;
			while (base != null) {
				accepted.push(typeId(Obj(base)));
				var next:Null<String> = null;
				for (candidate in program.objects)
					if (candidate.name == base)
						next = candidate.base;
				base = next;
			}
			for (interfaceName in object.interfaces)
				accepted.push(typeId(Virtual(interfaceName)));
			body.push(LocalGet(0));
			body.push(I32Load(0));
			body.push(I32Const(typeId(Obj(object.name))));
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
			I32Const(typeId(Bytes)),
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
				I32Const(typeId(Bytes)),
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
			I32Const(typeId(Bytes)),
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
			{type: I32}, {type: I32}, {type: I64}, {type: I32}, {type: I32}, {type: I32}, {type: I32}
		], body));
	}

	static function addDynamicString(module:WasmModule, name:String, allocator:Int, strings:Map<String, Int>, ryuTableBase:Int):Int {
		var integerString = addIntToString(module, "__haxeon_i32_to_string", allocator),
			int64String = addInt64ToString(module, "__haxeon_i64_to_string", allocator),
			floatString = WasmNumericString.addFloatToString(module, "__haxeon_f64_to_string", allocator, typeId(Bytes), ryuTableBase,
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
				I32Const(typeId(I64)),
				I32Eq,
				If(null),
				LocalGet(0),
				I64Load(WasmLayout.DYN_PAYLOAD_OFFSET),
				Call(int64String),
				Return,
				End,
				LocalGet(0),
				I32Load(0),
				I32Const(typeId(F64)),
				I32Eq,
				If(null),
				LocalGet(0),
				F64Load(WasmLayout.DYN_PAYLOAD_OFFSET),
				Call(floatString),
				Return,
				End,
				LocalGet(0),
				I32Load(0),
				I32Const(typeId(Bytes)),
				I32Eq,
				If(null),
				LocalGet(0),
				Return,
				End,
				LocalGet(0),
				I32Load(0),
				I32Const(typeId(I32)),
				I32Eq,
				If(null),
				LocalGet(0),
				I32Load(WasmLayout.DYN_PAYLOAD_OFFSET),
				Call(integerString),
				Return,
				End,
				LocalGet(0),
				I32Load(0),
				I32Const(typeId(Bool)),
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

	static function addArrayCopy(module:WasmModule, name:String, stride:Int, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: [I32]}, [for (_ in 0...4) {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(1),
			I32Const(WasmLayout.ARRAY_HEADER_SIZE),
			Call(allocator),
			LocalSet(2),
			LocalGet(2),
			I32Const(typeId(Array(Dyn))),
			I32Store(0),
			LocalGet(2),
			LocalGet(1),
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalGet(2),
			LocalGet(1),
			I32Const(8),
			I32Add,
			LocalTee(4),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(4),
			I32Const(stride),
			I32Mul,
			Call(allocator),
			LocalSet(3),
			LocalGet(3),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Sub,
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			LocalGet(2),
			I32Store(0),
			LocalGet(2),
			LocalGet(3),
			I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(1),
			I32Const(stride),
			I32Mul,
			MemoryCopy,
			LocalGet(2),
			Return
		]));
	}

	static function addArrayJoinBytes(module:WasmModule, name:String, allocator:Int, stringConcat:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32], results: [I32]}, [for (_ in 0...4) {type: I32}], [
			I32Const(WasmLayout.STRING_DATA_OFFSET),
			Call(allocator),
			LocalSet(2),
			LocalGet(2),
			I32Const(typeId(Bytes)),
			I32Store(0),
			LocalGet(2),
			I32Const(0),
			I32Store(WasmLayout.STRING_LENGTH_OFFSET),
			LocalGet(2),
			I32Const(0),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			I32Const(0),
			LocalSet(3),
			Block(null),
			Loop(null),
			LocalGet(3),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			I32LtS,
			If(null),
			LocalGet(3),
			I32Eqz,
			If(null),
			Else,
			LocalGet(2),
			LocalGet(1),
			Call(stringConcat),
			LocalSet(2),
			End,
			LocalGet(2),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(4),
			I32Mul,
			I32Add,
			I32Load(0),
			Call(stringConcat),
			LocalSet(2),
			LocalGet(3),
			I32Const(1),
			I32Add,
			LocalSet(3),
			Br(1),
			Else,
			Br(0),
			End,
			End,
			End,
			LocalGet(2),
			Return
		]));
	}

	static function addArrayIndexOf(module:WasmModule, name:String, stride:Int, elementType:WasmValueType, stringEqual:Null<Int>):Int {
		var compare = stringEqual == null ? (elementType == F64 ? F64Eq : I32Eq) : null;
		return module.addFunction(new WasmFunction(name, {parameters: [I32, elementType], results: [I32]}, [{type: I32}, {type: I32}], [
			I32Const(0),
			LocalSet(2),
			I32Const(-1),
			LocalSet(3),
			Block(null),
			Loop(null),
			LocalGet(2),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			I32LtS,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			I32Add,
			elementType == F64 ? F64Load(0) : I32Load(0),
			LocalGet(1),
			stringEqual == null ? compare : Call(stringEqual),
			If(null),
			LocalGet(2),
			LocalSet(3),
			Br(3),
			End,
			LocalGet(2),
			I32Const(1),
			I32Add,
			LocalSet(2),
			Br(1),
			Else,
			End,
			End,
			End,
			LocalGet(3),
			Return
		]));
	}

	static function addArraySlice(module:WasmModule, name:String, stride:Int, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32, I32], results: [I32]}, [for (_ in 0...6) {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(3),
			LocalGet(1),
			I32Const(0),
			I32LtS,
			If(null),
			LocalGet(3),
			LocalGet(1),
			I32Add,
			LocalSet(4),
			Else,
			LocalGet(1),
			LocalSet(4),
			End,
			LocalGet(4),
			I32Const(0),
			I32LtS,
			If(null),
			I32Const(0),
			LocalSet(4),
			End,
			LocalGet(4),
			LocalGet(3),
			I32LtS,
			If(null),
			Else,
			LocalGet(3),
			LocalSet(4),
			End,
			LocalGet(2),
			I32Const(0),
			I32LtS,
			If(null),
			LocalGet(3),
			LocalGet(2),
			I32Add,
			LocalSet(5),
			Else,
			LocalGet(2),
			LocalSet(5),
			End,
			LocalGet(5),
			I32Const(0),
			I32LtS,
			If(null),
			I32Const(0),
			LocalSet(5),
			End,
			LocalGet(5),
			LocalGet(3),
			I32LtS,
			If(null),
			Else,
			LocalGet(3),
			LocalSet(5),
			End,
			LocalGet(5),
			LocalGet(4),
			I32LtS,
			If(null),
			LocalGet(4),
			LocalSet(5),
			End,
			LocalGet(5),
			LocalGet(4),
			I32Sub,
			LocalSet(6),
			I32Const(WasmLayout.ARRAY_HEADER_SIZE),
			Call(allocator),
			LocalSet(7),
			LocalGet(7),
			I32Const(typeId(Array(Dyn))),
			I32Store(0),
			LocalGet(7),
			LocalGet(6),
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalGet(7),
			LocalGet(6),
			I32Const(8),
			I32Add,
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(6),
			I32Const(8),
			I32Add,
			I32Const(stride),
			I32Mul,
			Call(allocator),
			LocalSet(8),
			LocalGet(8),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Sub,
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			LocalGet(7),
			I32Store(0),
			LocalGet(7),
			LocalGet(8),
			I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(8),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(4),
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(6),
			I32Const(stride),
			I32Mul,
			MemoryCopy,
			LocalGet(7),
			Return
		]));
	}

	static function addArrayConcat(module:WasmModule, name:String, stride:Int, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32], results: [I32]}, [for (_ in 0...4) {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(2),
			LocalGet(1),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(3),
			I32Const(WasmLayout.ARRAY_HEADER_SIZE),
			Call(allocator),
			LocalSet(4),
			LocalGet(4),
			LocalGet(2),
			LocalGet(3),
			I32Add,
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalGet(4),
			LocalGet(2),
			LocalGet(3),
			I32Add,
			I32Const(8),
			I32Add,
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(4),
			I32Const(typeId(Array(Dyn))),
			I32Store(0),
			LocalGet(2),
			LocalGet(3),
			I32Add,
			I32Const(8),
			I32Add,
			I32Const(stride),
			I32Mul,
			Call(allocator),
			LocalSet(5),
			LocalGet(5),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Sub,
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			LocalGet(4),
			I32Store(0),
			LocalGet(4),
			LocalGet(5),
			I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(5),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			MemoryCopy,
			LocalGet(5),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(1),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(stride),
			I32Mul,
			MemoryCopy,
			LocalGet(4),
			Return
		]));
	}

	static function addArrayPush(module:WasmModule, name:String, stride:Int, elementType:WasmValueType, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, elementType], results: [I32]}, [for (_ in 0...4) {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(2),
			LocalGet(2),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
			I32LtS,
			If(null),
			Else,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalTee(3),
			I32Eqz,
			If(null),
			I32Const(8),
			LocalSet(3),
			Else,
			LocalGet(3),
			I32Const(2),
			I32Mul,
			LocalSet(3),
			End,
			LocalGet(3),
			I32Const(stride),
			I32Mul,
			Call(allocator),
			LocalSet(4),
			LocalGet(4),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Sub,
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			LocalGet(0),
			I32Store(0),
			LocalGet(4),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			MemoryCopy,
			LocalGet(0),
			LocalGet(4),
			I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(0),
			LocalGet(3),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			End,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(1),
			elementType == F64 ? F64Store(0) : I32Store(0),
			LocalGet(0),
			LocalGet(2),
			I32Const(1),
			I32Add,
			LocalTee(5),
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalGet(5),
			Return
		]));
	}

	static function addArrayPop(module:WasmModule, name:String, stride:Int, elementType:WasmValueType):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: [elementType]}, [{type: I32}, {type: I32}, {type: elementType}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(1),
			I32Const(0),
			LocalGet(1),
			I32LtS,
			If(null),
			LocalGet(1),
			I32Const(1),
			I32Sub,
			LocalSet(2),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			I32Add,
			elementType == F64 ? F64Load(0) : I32Load(0),
			LocalSet(3),
			LocalGet(0),
			LocalGet(2),
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			Else,
			Unreachable,
			End,
			LocalGet(3),
			Return
		]));
	}

	static function addArrayUnshift(module:WasmModule, name:String, stride:Int, elementType:WasmValueType, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, elementType], results: [I32]}, [for (_ in 0...4) {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(2),
			LocalGet(2),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
			I32LtS,
			If(null),
			Else,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalTee(4),
			I32Eqz,
			If(null),
			I32Const(8),
			LocalSet(4),
			Else,
			LocalGet(4),
			I32Const(2),
			I32Mul,
			LocalSet(4),
			End,
			LocalGet(4),
			I32Const(stride),
			I32Mul,
			Call(allocator),
			LocalSet(5),
			LocalGet(5),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Sub,
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			LocalGet(0),
			I32Store(0),
			LocalGet(5),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			MemoryCopy,
			LocalGet(0),
			LocalGet(5),
			I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(0),
			LocalGet(4),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			End,
			LocalGet(2),
			LocalSet(3),
			Block(null),
			Loop(null),
			I32Const(0),
			LocalGet(3),
			I32LtS,
			If(null),
			LocalGet(3),
			I32Const(1),
			I32Sub,
			LocalSet(3),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(1),
			I32Add,
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(stride),
			I32Mul,
			I32Add,
			elementType == F64 ? F64Load(0) : I32Load(0),
			elementType == F64 ? F64Store(0) : I32Store(0),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(1),
			elementType == F64 ? F64Store(0) : I32Store(0),
			LocalGet(0),
			LocalGet(2),
			I32Const(1),
			I32Add,
			LocalTee(3),
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalGet(3),
			Return
		]));
	}

	static function addArrayInsert(module:WasmModule, name:String, stride:Int, elementType:WasmValueType, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32, elementType], results: []}, [for (_ in 0...5) {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(3),
			LocalGet(1),
			I32Const(0),
			I32LtS,
			If(null),
			I32Const(0),
			LocalSet(4),
			Else,
			LocalGet(1),
			LocalSet(4),
			End,
			LocalGet(4),
			LocalGet(3),
			I32LtS,
			If(null),
			Else,
			LocalGet(3),
			LocalSet(4),
			End,
			LocalGet(3),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
			I32LtS,
			If(null),
			Else,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalTee(6),
			I32Eqz,
			If(null),
			I32Const(8),
			LocalSet(6),
			Else,
			LocalGet(6),
			I32Const(2),
			I32Mul,
			LocalSet(6),
			End,
			LocalGet(6),
			I32Const(stride),
			I32Mul,
			Call(allocator),
			LocalSet(7),
			LocalGet(7),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Sub,
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			LocalGet(0),
			I32Store(0),
			LocalGet(7),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(stride),
			I32Mul,
			MemoryCopy,
			LocalGet(0),
			LocalGet(7),
			I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(0),
			LocalGet(6),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			End,
			LocalGet(3),
			LocalSet(5),
			Block(null),
			Loop(null),
			LocalGet(4),
			LocalGet(5),
			I32LtS,
			If(null),
			LocalGet(5),
			I32Const(1),
			I32Sub,
			LocalSet(5),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(5),
			I32Const(1),
			I32Add,
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(5),
			I32Const(stride),
			I32Mul,
			I32Add,
			elementType == F64 ? F64Load(0) : I32Load(0),
			elementType == F64 ? F64Store(0) : I32Store(0),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(4),
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(2),
			elementType == F64 ? F64Store(0) : I32Store(0),
			LocalGet(0),
			LocalGet(3),
			I32Const(1),
			I32Add,
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET)
		]));
	}

	static function addArrayShift(module:WasmModule, name:String, stride:Int, elementType:WasmValueType):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: [elementType]}, [{type: I32}, {type: elementType}, {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(1),
			I32Const(0),
			LocalGet(1),
			I32LtS,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			elementType == F64 ? F64Load(0) : I32Load(0),
			LocalSet(2),
			I32Const(1),
			LocalSet(3),
			Block(null),
			Loop(null),
			LocalGet(3),
			LocalGet(1),
			I32LtS,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(1),
			I32Sub,
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(stride),
			I32Mul,
			I32Add,
			elementType == F64 ? F64Load(0) : I32Load(0),
			elementType == F64 ? F64Store(0) : I32Store(0),
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
			LocalGet(1),
			I32Const(1),
			I32Sub,
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			Else,
			Unreachable,
			End,
			LocalGet(2),
			Return
		]));
	}

	static function addArrayResize(module:WasmModule, name:String, stride:Int, elementType:WasmValueType, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32], results: []}, [for (_ in 0...4) {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(2),
			LocalGet(1),
			I32Const(0),
			I32LtS,
			If(null),
			Unreachable,
			Else,
			LocalGet(1),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
			I32LeS,
			If(null),
			LocalGet(2),
			LocalSet(3),
			Block(null),
			Loop(null),
			LocalGet(3),
			LocalGet(1),
			I32LtS,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(stride),
			I32Mul,
			I32Add,
			elementType == F64 ? F64Const(0.0) : I32Const(0),
			elementType == F64 ? F64Store(0) : I32Store(0),
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
			LocalGet(1),
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			Else,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_CAPACITY_OFFSET),
			I32Const(2),
			I32Mul,
			LocalSet(4),
			LocalGet(4),
			LocalGet(1),
			I32LtS,
			If(null),
			LocalGet(1),
			LocalSet(4),
			End,
			LocalGet(4),
			I32Const(stride),
			I32Mul,
			Call(allocator),
			LocalSet(5),
			LocalGet(5),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Sub,
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			LocalGet(0),
			I32Store(0),
			LocalGet(5),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			MemoryCopy,
			LocalGet(0),
			LocalGet(5),
			I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(0),
			LocalGet(4),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			End,
			End
		]));
	}

	static function addArrayRemove(module:WasmModule, name:String, stride:Int, elementType:WasmValueType, stringEqual:Null<Int>):Int {
		var compare = stringEqual == null ? (elementType == F64 ? F64Eq : I32Eq) : null;
		return module.addFunction(new WasmFunction(name, {parameters: [I32, elementType], results: [I32]}, [{type: I32}, {type: I32}, {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(2),
			I32Const(0),
			LocalSet(3),
			I32Const(-1),
			LocalSet(4),
			Block(null),
			Loop(null),
			LocalGet(3),
			LocalGet(2),
			I32LtS,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(stride),
			I32Mul,
			I32Add,
			elementType == F64 ? F64Load(0) : I32Load(0),
			LocalGet(1),
			stringEqual == null ? compare : Call(stringEqual),
			If(null),
			LocalGet(3),
			LocalSet(4),
			Br(3),
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
			I32Const(-1),
			LocalGet(4),
			I32LtS,
			If(null),
			LocalGet(4),
			I32Const(1),
			I32Add,
			LocalSet(3),
			Block(null),
			Loop(null),
			LocalGet(3),
			LocalGet(2),
			I32LtS,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(1),
			I32Sub,
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(stride),
			I32Mul,
			I32Add,
			elementType == F64 ? F64Load(0) : I32Load(0),
			elementType == F64 ? F64Store(0) : I32Store(0),
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
			LocalGet(2),
			I32Const(1),
			I32Sub,
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			I32Const(1),
			LocalSet(4),
			Else,
			I32Const(0),
			LocalSet(4),
			End,
			LocalGet(4),
			Return
		]));
	}

	static function addArrayReverse(module:WasmModule, name:String, stride:Int, elementType:WasmValueType):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32], results: []}, [{type: I32}, {type: I32}, {type: I32}, {type: elementType}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(1),
			I32Const(0),
			LocalSet(2),
			LocalGet(1),
			I32Const(1),
			I32Sub,
			LocalSet(3),
			Block(null),
			Loop(null),
			LocalGet(2),
			LocalGet(3),
			I32LtS,
			If(null),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			I32Add,
			elementType == F64 ? F64Load(0) : I32Load(0),
			LocalSet(4),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(stride),
			I32Mul,
			I32Add,
			elementType == F64 ? F64Load(0) : I32Load(0),
			elementType == F64 ? F64Store(0) : I32Store(0),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(3),
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(4),
			elementType == F64 ? F64Store(0) : I32Store(0),
			LocalGet(2),
			I32Const(1),
			I32Add,
			LocalSet(2),
			LocalGet(3),
			I32Const(1),
			I32Sub,
			LocalSet(3),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End
		]));
	}

	static function addArraySplice(module:WasmModule, name:String, stride:Int, allocator:Int):Int {
		return module.addFunction(new WasmFunction(name, {parameters: [I32, I32, I32], results: [I32]}, [for (_ in 0...6) {type: I32}], [
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(3),
			LocalGet(1),
			I32Const(0),
			I32LtS,
			If(null),
			LocalGet(3),
			LocalGet(1),
			I32Add,
			LocalSet(4),
			Else,
			LocalGet(1),
			LocalSet(4),
			End,
			LocalGet(4),
			I32Const(0),
			I32LtS,
			If(null),
			I32Const(0),
			LocalSet(4),
			End,
			LocalGet(4),
			LocalGet(3),
			I32LtS,
			If(null),
			Else,
			LocalGet(3),
			LocalSet(4),
			End,
			LocalGet(2),
			I32Const(0),
			I32LtS,
			If(null),
			I32Const(0),
			LocalSet(5),
			Else,
			LocalGet(2),
			LocalSet(5),
			End,
			LocalGet(5),
			LocalGet(3),
			LocalGet(4),
			I32Sub,
			I32LtS,
			If(null),
			Else,
			LocalGet(3),
			LocalGet(4),
			I32Sub,
			LocalSet(5),
			End,
			I32Const(WasmLayout.ARRAY_HEADER_SIZE),
			Call(allocator),
			LocalSet(6),
			LocalGet(6),
			I32Const(typeId(Array(Dyn))),
			I32Store(0),
			LocalGet(6),
			LocalGet(5),
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalGet(6),
			LocalGet(5),
			I32Const(8),
			I32Add,
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(5),
			I32Const(8),
			I32Add,
			I32Const(stride),
			I32Mul,
			Call(allocator),
			LocalSet(8),
			LocalGet(8),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Sub,
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			LocalGet(6),
			I32Store(0),
			LocalGet(6),
			LocalGet(8),
			I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(8),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(4),
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(5),
			I32Const(stride),
			I32Mul,
			MemoryCopy,
			LocalGet(3),
			LocalGet(4),
			I32Sub,
			LocalGet(5),
			I32Sub,
			LocalSet(7),
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(4),
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(0),
			I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(4),
			LocalGet(5),
			I32Add,
			I32Const(stride),
			I32Mul,
			I32Add,
			LocalGet(7),
			I32Const(stride),
			I32Mul,
			MemoryCopy,
			LocalGet(0),
			LocalGet(3),
			LocalGet(5),
			I32Sub,
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalGet(6),
			Return
		]));
	}

	static function stringBytes(value:String):HaxeBytes {
		var raw = HaxeBytes.ofString(value),
			bytes = HaxeBytes.alloc(WasmLayout.STRING_DATA_OFFSET + raw.length + 1);
		bytes.setInt32(0, typeId(Bytes));
		bytes.setInt32(WasmLayout.STRING_LENGTH_OFFSET, raw.length);
		bytes.setInt32(WasmLayout.ARRAY_CAPACITY_OFFSET, raw.length);
		for (index in 0...raw.length)
			bytes.set(WasmLayout.STRING_DATA_OFFSET + index, raw.get(index));
		return bytes;
	}

	static function zeroValue(type:IrType):Array<WasmInstruction>
		return switch type {
			case I64: [I64Const(0)];
			case F64: [F64Const(0.0)];
			case Void: [];
			default: [I32Const(0)];
		};

	static function align(value:Int, boundary:Int):Int
		return (value + boundary - 1) & ~(boundary - 1);

	static function addGcMark(module:WasmModule, heapStart:Int, heapTop:Int, markStackTop:Int):Int {
		var type:WasmFunctionType = {parameters: [I32], results: []},
			index = module.addFunction(new WasmFunction("__haxeon_gc_mark", type));
		var body:Array<WasmInstruction> = [
			LocalGet(0),
			I32Eqz,
			If(null),
			Return,
			End,
			LocalGet(0),
			I32Const(heapStart + WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32LtS,
			If(null),
			Return,
			End,
			LocalGet(0),
			I32Const(7),
			I32And,
			I32Eqz,
			I32Eqz,
			If(null),
			Return,
			End,
			LocalGet(0),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Sub,
			LocalSet(1),
			GlobalGet(heapTop),
			LocalGet(1),
			I32LeS,
			If(null),
			Return,
			End,
			LocalGet(0),
			GlobalGet(heapTop),
			I32LeS,
			I32Eqz,
			If(null),
			Return,
			End,
			LocalGet(1),
			I32Load(WasmLayout.GC_BLOCK_FLAGS_OFFSET),
			LocalSet(2),
			LocalGet(2),
			I32Const(WasmLayout.GC_BLOCK_MAGIC_MASK),
			I32And,
			I32Const(WasmLayout.GC_BLOCK_MAGIC),
			I32Eq,
			I32Eqz,
			If(null),
			Return,
			End,
			LocalGet(2),
			I32Const(WasmLayout.GC_BLOCK_ALLOCATED),
			I32And,
			I32Eqz,
			If(null),
			Return,
			End,
			LocalGet(1),
			I32Load(WasmLayout.GC_BLOCK_OWNER_OFFSET),
			LocalGet(0),
			I32Eq,
			I32Eqz,
			If(null),
			Return,
			End,
			LocalGet(1),
			I32Load(WasmLayout.GC_BLOCK_SIZE_OFFSET),
			LocalSet(3),
			LocalGet(3),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32LtS,
			If(null),
			Return,
			End,
			LocalGet(3),
			I32Const(7),
			I32And,
			I32Eqz,
			I32Eqz,
			If(null),
			Return,
			End,
			LocalGet(3),
			GlobalGet(heapTop),
			LocalGet(1),
			I32Sub,
			I32LeS,
			I32Eqz,
			If(null),
			Return,
			End,
			LocalGet(2),
			I32Const(WasmLayout.GC_BLOCK_MARKED),
			I32And,
			If(null),
			Return,
			End,
			LocalGet(1),
			I32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET),
			I32Add,
			LocalGet(2),
			I32Const(WasmLayout.GC_BLOCK_MARKED),
			I32Or,
			I32Store(0),
			LocalGet(2),
			I32Const(WasmLayout.GC_BLOCK_SCAN_REFERENCES),
			I32And,
			I32Eqz,
			If(null),
			Return,
			End,
			GlobalGet(markStackTop),
			I32Const(4),
			I32Add,
			MemorySize,
			I32Const(65536),
			I32Mul,
			I32LeS,
			I32Eqz,
			If(null),
			I32Const(1),
			MemoryGrow,
			I32Const(-1),
			I32Eq,
			If(null),
			Unreachable,
			End,
			End,
			GlobalGet(markStackTop),
			LocalGet(1),
			I32Store(0),
			GlobalGet(markStackTop),
			I32Const(4),
			I32Add,
			GlobalSet(markStackTop),
			Return
		];
		module.setFunction(index, new WasmFunction("__haxeon_gc_mark", type, [for (_ in 0...3) {type: I32}], body));
		return index;
	}

	static function addGcTrace(module:WasmModule, program:IrProgram, layout:WasmLayout, mark:Int):Int {
		var type:WasmFunctionType = {parameters: [I32], results: []},
			index = module.addFunction(new WasmFunction("__haxeon_gc_trace", type));
		var body:Array<WasmInstruction> = [LocalGet(0), I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE), I32Sub, LocalSet(1)];
		var mapNames:Array<String> = [];
		for (native in program.natives) {
			var parts = mapNativeParts(native.name);
			if (parts != null && parts.operation == "alloc" && mapNames.indexOf(parts.mapName) < 0)
				mapNames.push(parts.mapName);
		}
		mapNames.sort(Reflect.compare);

		// Array and map backing blocks keep their owner in the auxiliary block
		// link while allocated. Trace only the active logical entries.
		body = body.concat([
			LocalGet(1),
			I32Load(WasmLayout.GC_BLOCK_LINK_OFFSET),
			LocalTee(5),
			I32Eqz,
			If(null),
			Else
		]);
		body.push(LocalGet(5));
		body.push(I32Load(0));
		body.push(I32Const(typeId(Array(Dyn))));
		body.push(I32Eq);
		body.push(If(null));
		appendGcArrayContents(body, mark);
		body.push(Return);
		body.push(End);
		for (mapName in mapNames) {
			body.push(LocalGet(5));
			body.push(I32Load(0));
			body.push(I32Const(typeId(Abstract(mapName))));
			body.push(I32Eq);
			body.push(If(null));
			appendGcMapContents(body, mark, mapName);
			body.push(Return);
			body.push(End);
		}
		appendGcConservativeTrace(body, mark);
		body.push(Return);
		body.push(End);

		// Primitive boxes and byte payloads are leaves. Other known layouts are
		// traced from their declared reference fields, not by scanning scalars.
		var leafTypes:Array<IrType> = [Bytes, I32, Bool, I64, F64];
		for (leaf in leafTypes)
			appendGcTraceCase(body, typeId(leaf), []);
		for (object in program.objects) {
			var references = [];
			for (field in layout.object(object.name).fields)
				if (WasmTarget.isReference(field.type))
					references = references.concat([LocalGet(0), I32Load(field.offset), Call(mark)]);
			appendGcTraceCase(body, typeId(Obj(object.name)), references);
		}
		for (enumDecl in program.enums) {
			var enumLayout = layout.enumType(enumDecl.name);
			body = body.concat([
				LocalGet(0),
				I32Load(0),
				I32Const(typeId(Enum(enumDecl.name))),
				I32Eq,
				If(null),
				LocalGet(0),
				I32Load(WasmLayout.HEADER_SIZE),
				LocalSet(5)
			]);
			for (caseIndex in 0...enumLayout.cases.length) {
				var references:Array<WasmInstruction> = [];
				for (fieldIndex in 0...enumLayout.cases[caseIndex].length) {
					var field = layout.enumField(enumDecl.name, caseIndex, fieldIndex);
					if (WasmTarget.isReference(field.type))
						references = references.concat([LocalGet(0), I32Load(field.offset), Call(mark)]);
				}
				body = body.concat([LocalGet(5), I32Const(caseIndex), I32Eq, If(null)]);
				body = body.concat(references);
				body = body.concat([Return, End]);
			}
			body = body.concat([Return, End]);
		}
		for (mapName in mapNames)
			appendGcTraceCase(body, typeId(Abstract(mapName)), [LocalGet(0), I32Load(WasmLayout.MAP_ENTRIES_OFFSET), Call(mark)]);
		appendGcTraceCase(body, typeId(Array(Dyn)), [LocalGet(0), I32Load(WasmLayout.ARRAY_DATA_POINTER_OFFSET), Call(mark)]);
		appendGcTraceCase(body, typeId(Abstract("realtime_iterator")), [LocalGet(0), I32Load(WasmLayout.ITERATOR_ARRAY_OFFSET), Call(mark)]);
		appendGcTraceCase(body, WasmLayout.CLOSURE_TYPE_ID, [LocalGet(0), I32Load(WasmLayout.CLOSURE_RECEIVER_OFFSET), Call(mark)]);
		appendGcConservativeTrace(body, mark);
		body.push(Return);
		module.setFunction(index, new WasmFunction("__haxeon_gc_trace", type, [for (_ in 0...5) {type: I32}], body));
		return index;
	}

	static function appendGcTraceCase(body:Array<WasmInstruction>, id:Int, trace:Array<WasmInstruction>):Void {
		body.push(LocalGet(0));
		body.push(I32Load(0));
		body.push(I32Const(id));
		body.push(I32Eq);
		body.push(If(null));
		for (instruction in trace)
			body.push(instruction);
		body.push(Return);
		body.push(End);
	}

	static function appendGcArrayContents(body:Array<WasmInstruction>, mark:Int):Void {
		append(body, [
			LocalGet(5),
			I32Load(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalSet(3),
			I32Const(0),
			LocalSet(4),
			Block(null),
			Loop(null),
			LocalGet(4),
			LocalGet(3),
			I32LtS,
			If(null),
			LocalGet(0),
			LocalGet(4),
			I32Const(4),
			I32Mul,
			I32Add,
			I32Load(0),
			Call(mark),
			LocalGet(4),
			I32Const(1),
			I32Add,
			LocalSet(4),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End
		]);
	}

	static function appendGcMapContents(body:Array<WasmInstruction>, mark:Int, mapName:String):Void {
		var keyType = mapKeyType(mapName),
			valueType = mapValueType(mapName),
			entrySize = mapEntrySize(valueType),
			valueOffset = mapValueOffset(valueType);
		append(body, [
			LocalGet(5),
			I32Load(WasmLayout.MAP_COUNT_OFFSET),
			LocalSet(3),
			I32Const(0),
			LocalSet(4),
			Block(null),
			Loop(null),
			LocalGet(4),
			LocalGet(3),
			I32LtS,
			If(null)
		]);
		if (WasmTarget.isReference(keyType))
			append(body, [
				LocalGet(0),
				LocalGet(4),
				I32Const(entrySize),
				I32Mul,
				I32Add,
				I32Load(0),
				Call(mark)
			]);
		if (WasmTarget.isReference(valueType))
			append(body, [
				LocalGet(0),
				LocalGet(4),
				I32Const(entrySize),
				I32Mul,
				I32Add,
				I32Load(valueOffset),
				Call(mark)
			]);
		append(body, [LocalGet(4), I32Const(1), I32Add, LocalSet(4), Br(1), Else, Br(2), End, End, End]);
	}

	static function appendGcConservativeTrace(body:Array<WasmInstruction>, mark:Int):Void {
		append(body, [
			LocalGet(1),
			I32Load(WasmLayout.GC_BLOCK_SIZE_OFFSET),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Sub,
			LocalSet(3),
			I32Const(0),
			LocalSet(4),
			Block(null),
			Loop(null),
			LocalGet(4),
			LocalGet(3),
			I32LtS,
			If(null),
			LocalGet(0),
			LocalGet(4),
			I32Add,
			I32Load(0),
			Call(mark),
			LocalGet(4),
			I32Const(4),
			I32Add,
			LocalSet(4),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End
		]);
	}

	static function addGcCollector(module:WasmModule, heapStart:Int, heapTop:Int, rootFrameTop:Int, freeHead:Int, mark:Int, trace:Int, markStackTop:Int,
			rootGlobals:Array<Int>, collectionCount:Int):Int {
		var type:WasmFunctionType = {parameters: [], results: []},
			body:Array<WasmInstruction> = [];
		body = body.concat([GlobalGet(heapTop), GlobalSet(markStackTop)]);
		if (collectionCount >= 0)
			body = body.concat([GlobalGet(collectionCount), I32Const(1), I32Add, GlobalSet(collectionCount)]);
		body = body.concat([
			GlobalGet(rootFrameTop),
			LocalSet(0),
			Block(null),
			Loop(null),
			LocalGet(0),
			I32Eqz,
			If(null),
			Br(2),
			Else,
			LocalGet(0),
			I32Load(WasmLayout.ROOT_COUNT_OFFSET),
			LocalSet(1),
			I32Const(0),
			LocalSet(2),
			Block(null),
			Loop(null),
			LocalGet(2),
			LocalGet(1),
			I32LtS,
			If(null),
			LocalGet(0),
			I32Const(WasmLayout.ROOT_VALUES_OFFSET),
			I32Add,
			LocalGet(2),
			I32Const(4),
			I32Mul,
			I32Add,
			I32Load(0),
			Call(mark),
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
			LocalGet(0),
			I32Load(WasmLayout.ROOT_PREVIOUS_FRAME_OFFSET),
			LocalSet(0),
			Br(1),
			End,
			End,
			End,
		]);
		for (global in rootGlobals) {
			body.push(GlobalGet(global));
			body.push(Call(mark));
		}
		body = body.concat([
			Block(null),
			Loop(null),
			GlobalGet(markStackTop),
			GlobalGet(heapTop),
			I32LeS,
			BrIf(1),
			GlobalGet(markStackTop),
			I32Const(4),
			I32Sub,
			GlobalSet(markStackTop),
			GlobalGet(markStackTop),
			I32Load(0),
			LocalSet(8),
			GlobalGet(markStackTop),
			I32Const(0),
			I32Store(0),
			LocalGet(8),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Add,
			Call(trace),
			Br(0),
			End,
			End
		]);
		var appendFreeRun:Array<WasmInstruction> = [
			LocalGet(7),
			I32Eqz,
			If(null),
			LocalGet(3),
			LocalSet(6),
			End,
			LocalGet(7),
			LocalGet(4),
			I32Add,
			LocalSet(7)
		];
		var flushFreeRun:Array<WasmInstruction> = [
			LocalGet(7),
			I32Eqz,
			I32Eqz,
			If(null),
			LocalGet(6),
			LocalGet(7),
			I32Store(WasmLayout.GC_BLOCK_SIZE_OFFSET),
			LocalGet(6),
			I32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET),
			I32Add,
			I32Const(WasmLayout.GC_BLOCK_MAGIC),
			I32Store(0),
			LocalGet(6),
			I32Const(WasmLayout.GC_BLOCK_OWNER_OFFSET),
			I32Add,
			I32Const(0),
			I32Store(0),
			LocalGet(6),
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			GlobalGet(freeHead),
			I32Store(0),
			LocalGet(6),
			GlobalSet(freeHead),
			End
		];
		body = body.concat([
			I32Const(0),
			GlobalSet(freeHead),
			I32Const(heapStart),
			LocalSet(3),
			I32Const(0),
			LocalSet(6),
			I32Const(0),
			LocalSet(7),
			Block(null),
			Loop(null),
			LocalGet(3),
			GlobalGet(heapTop),
			I32LtS,
			If(null),
			LocalGet(3),
			I32Load(WasmLayout.GC_BLOCK_SIZE_OFFSET),
			LocalSet(4),
			LocalGet(4),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32LtS,
			If(null),
			Unreachable,
			End,
			LocalGet(4),
			I32Const(7),
			I32And,
			I32Eqz,
			I32Eqz,
			If(null),
			Unreachable,
			End,
			LocalGet(4),
			GlobalGet(heapTop),
			LocalGet(3),
			I32Sub,
			I32LeS,
			I32Eqz,
			If(null),
			Unreachable,
			End,
			LocalGet(3),
			I32Load(WasmLayout.GC_BLOCK_FLAGS_OFFSET),
			LocalSet(5),
			LocalGet(5),
			I32Const(WasmLayout.GC_BLOCK_MAGIC_MASK),
			I32And,
			I32Const(WasmLayout.GC_BLOCK_MAGIC),
			I32Eq,
			I32Eqz,
			If(null),
			Unreachable,
			End,
			LocalGet(5),
			I32Const(WasmLayout.GC_BLOCK_ALLOCATED),
			I32And,
			If(null),
			LocalGet(5),
			I32Const(WasmLayout.GC_BLOCK_MARKED),
			I32And,
			If(null)
		]);
		body = body.concat(flushFreeRun);
		body = body.concat([
			I32Const(0),
			LocalSet(6),
			I32Const(0),
			LocalSet(7),
			LocalGet(3),
			I32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET),
			I32Add,
			LocalGet(5),
			I32Const(WasmLayout.GC_BLOCK_CLEAR_MARKED_MASK),
			I32And,
			I32Store(0),
			Else
		]);
		body = body.concat(appendFreeRun);
		body = body.concat([End, Else]);
		body = body.concat(appendFreeRun);
		body = body.concat([
			End,
			LocalGet(3),
			LocalGet(4),
			I32Add,
			LocalSet(3),
			Br(1),
			Else,
			Br(2),
			End,
			End,
			End
		]);
		body = body.concat(flushFreeRun);
		body.push(Return);
		return module.addFunction(new WasmFunction("__haxeon_gc_collect", type, [for (_ in 0...9) {type: I32}], body));
	}

	static function addAllocator(module:WasmModule, collector:Int, heapStart:Int, heapTop:Int, freeHead:Int, gcBudget:Int, gcStress:Bool, allocationCount:Int,
			allocationBytes:Int, largestAllocation:Int):Int {
		var type:WasmFunctionType = {parameters: [I32], results: [I32]};
		var index = module.addFunction(new WasmFunction("__haxeon_alloc", type));
		// local 10 keeps requested payload bytes for diagnostics; local 0 becomes
		// the complete physical block size. Locals 5/11/12 track GC/reuse state.
		var findFreeBlock:Array<WasmInstruction> = [
			I32Const(0),
			LocalSet(1),
			I32Const(0),
			LocalSet(4),
			I32Const(0),
			LocalSet(11),
			GlobalGet(freeHead),
			LocalSet(3),
			Block(null),
			Loop(null),
			LocalGet(3),
			I32Eqz,
			If(null),
			Br(2),
			Else,
			LocalGet(3),
			I32Load(WasmLayout.GC_BLOCK_SIZE_OFFSET),
			LocalSet(7),
			LocalGet(3),
			I32Load(WasmLayout.GC_BLOCK_LINK_OFFSET),
			LocalSet(9),
			LocalGet(0),
			LocalGet(7),
			I32LeS,
			If(null),
			LocalGet(3),
			LocalSet(1),
			LocalGet(7),
			LocalGet(0),
			I32Sub,
			LocalSet(8),
			LocalGet(8),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32LtS,
			If(null),
			// Consume a tail too small to hold another complete block header.
			LocalGet(7),
			LocalSet(6),
			LocalGet(4),
			I32Eqz,
			If(null),
			LocalGet(9),
			GlobalSet(freeHead),
			Else,
			LocalGet(4),
			LocalGet(9),
			I32Store(WasmLayout.GC_BLOCK_LINK_OFFSET),
			End,
			Else,
			LocalGet(0),
			LocalSet(6),
			LocalGet(3),
			LocalGet(0),
			I32Add,
			LocalSet(2),
			LocalGet(2),
			LocalGet(8),
			I32Store(WasmLayout.GC_BLOCK_SIZE_OFFSET),
			LocalGet(2),
			I32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET),
			I32Add,
			I32Const(WasmLayout.GC_BLOCK_MAGIC),
			I32Store(0),
			LocalGet(2),
			I32Const(WasmLayout.GC_BLOCK_OWNER_OFFSET),
			I32Add,
			I32Const(0),
			I32Store(0),
			LocalGet(2),
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			LocalGet(9),
			I32Store(0),
			LocalGet(4),
			I32Eqz,
			If(null),
			LocalGet(2),
			GlobalSet(freeHead),
			Else,
			LocalGet(4),
			LocalGet(2),
			I32Store(WasmLayout.GC_BLOCK_LINK_OFFSET),
			End,
			End,
			I32Const(1),
			LocalSet(11),
			Br(3),
			Else,
			LocalGet(3),
			LocalSet(4),
			LocalGet(9),
			LocalSet(3),
			End,
			End,
			Br(0),
			End,
			End
		];
		var replenishBudget:Array<WasmInstruction> = [
			GlobalGet(heapTop),
			I32Const(heapStart),
			I32Sub,
			LocalSet(12),
			LocalGet(12),
			I32Const(WasmLayout.GC_MIN_ALLOCATION_BUDGET),
			I32LtS,
			If(null),
			I32Const(WasmLayout.GC_MIN_ALLOCATION_BUDGET),
			LocalSet(12),
			End,
			LocalGet(12),
			LocalGet(0),
			I32Sub,
			GlobalSet(gcBudget)
		];
		var body:Array<WasmInstruction> = [LocalGet(0), I32Const(7), I32Add, I32Const(-8), I32And, LocalSet(10)];
		if (allocationCount >= 0 && allocationBytes >= 0)
			body = body.concat([
				GlobalGet(allocationCount),
				I32Const(1),
				I32Add,
				GlobalSet(allocationCount),
				GlobalGet(allocationBytes),
				LocalGet(10),
				I32Add,
				GlobalSet(allocationBytes)
			]);
		if (largestAllocation >= 0)
			body = body.concat([
				GlobalGet(largestAllocation),
				LocalGet(10),
				I32LtS,
				If(null),
				LocalGet(10),
				GlobalSet(largestAllocation),
				End
			]);
		body = body.concat([
			LocalGet(10),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Add,
			LocalSet(0),
			I32Const(0),
			LocalSet(5)
		]);
		if (gcStress) {
			body = body.concat([Call(collector), I32Const(1), LocalSet(5)]);
		} else {
			body = body.concat([
				GlobalGet(gcBudget),
				LocalGet(0),
				I32LtS,
				If(null),
				Call(collector),
				I32Const(1),
				LocalSet(5)
			]);
			body = body.concat(replenishBudget);
			body = body.concat([Else, GlobalGet(gcBudget), LocalGet(0), I32Sub, GlobalSet(gcBudget), End]);
		}
		body = body.concat(findFreeBlock);
		body = body.concat([
			LocalGet(1),
			I32Eqz,
			If(null),
			GlobalGet(heapTop),
			LocalGet(0),
			I32Add,
			LocalSet(2),
			MemorySize,
			I32Const(65536),
			I32Mul,
			LocalGet(2),
			I32LtS,
			If(null),
			LocalGet(5),
			I32Eqz,
			If(null),
			// Collection on pressure is mandatory even before the budget expires.
			Call(collector),
			I32Const(1),
			LocalSet(5)
		]);
		if (!gcStress)
			body = body.concat(replenishBudget);
		body = body.concat(findFreeBlock);
		body = body.concat([End, End, End]);
		body = body.concat([
			LocalGet(1),
			I32Eqz,
			If(null),
			GlobalGet(heapTop),
			LocalSet(1),
			LocalGet(0),
			LocalSet(6),
			LocalGet(1),
			LocalGet(0),
			I32Add,
			LocalSet(2),
			MemorySize,
			I32Const(65536),
			I32Mul,
			LocalGet(2),
			I32LtS,
			If(null),
			LocalGet(2),
			I32Const(65535),
			I32Add,
			I32Const(65536),
			I32DivS,
			MemorySize,
			I32Sub,
			MemoryGrow,
			I32Const(-1),
			I32Eq,
			If(null),
			Unreachable,
			End,
			End,
			LocalGet(2),
			GlobalSet(heapTop),
			End,
			// Reused blocks must be cleared to preserve Haxe's zero defaults;
			// newly grown linear-memory pages are already zero-filled.
			LocalGet(11),
			If(null),
			LocalGet(1),
			I32Const(0),
			LocalGet(6),
			MemoryFill,
			End,
			LocalGet(1),
			LocalGet(6),
			I32Store(WasmLayout.GC_BLOCK_SIZE_OFFSET),
			LocalGet(1),
			I32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET),
			I32Add,
			I32Const(WasmLayout.GC_BLOCK_MAGIC | WasmLayout.GC_BLOCK_ALLOCATED | WasmLayout.GC_BLOCK_SCAN_REFERENCES),
			I32Store(0),
			LocalGet(1),
			I32Const(WasmLayout.GC_BLOCK_OWNER_OFFSET),
			I32Add,
			LocalGet(1),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Add,
			I32Store(0),
			LocalGet(1),
			I32Const(WasmLayout.GC_BLOCK_LINK_OFFSET),
			I32Add,
			I32Const(0),
			I32Store(0),
			LocalGet(1),
			I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
			I32Add,
			Return
		]);
		module.setFunction(index, new WasmFunction("__haxeon_alloc", type, [for (_ in 0...12) {type: I32}], body));
		return index;
	}

	static function addArrayAllocator(module:WasmModule, name:String, stride:Int, allocator:Int):Int {
		var type:WasmFunctionType = {parameters: [I32], results: [I32]};
		var body:Array<WasmInstruction> = [
			I32Const(WasmLayout.ARRAY_HEADER_SIZE),
			Call(allocator),
			LocalSet(1),
			LocalGet(1),
			I32Const(typeId(Array(Dyn))),
			I32Store(0),
			LocalGet(1),
			LocalGet(0),
			I32Store(WasmLayout.ARRAY_LENGTH_OFFSET),
			LocalGet(1),
			LocalGet(0),
			I32Const(8),
			I32Add,
			LocalTee(2),
			I32Store(WasmLayout.ARRAY_CAPACITY_OFFSET),
			LocalGet(2),
			I32Const(stride),
			I32Mul,
			Call(allocator),
			LocalSet(3)
		];
		if (name == "__array_alloc_i32" || name == "__array_alloc_bool" || name == "__array_alloc_f64")
			body = body.concat([
				LocalGet(3),
				I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
				I32Sub,
				I32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET),
				I32Add,
				LocalGet(3),
				I32Const(WasmLayout.GC_BLOCK_HEADER_SIZE),
				I32Sub,
				I32Const(WasmLayout.GC_BLOCK_FLAGS_OFFSET),
				I32Add,
				I32Load(0),
				I32Const(WasmLayout.GC_BLOCK_CLEAR_SCAN_MASK),
				I32And,
				I32Store(0)
			]);
		else
			appendGcContainerOwner(body, 3, 1);
		body = body.concat([
			LocalGet(1),
			LocalGet(3),
			I32Store(WasmLayout.ARRAY_DATA_POINTER_OFFSET),
			LocalGet(1),
			Return
		]);
		return module.addFunction(new WasmFunction(name, type, [{type: I32}, {type: I32}, {type: I32}], body));
	}

	static function arrayStrideForNative(name:String):Null<Int>
		return switch name {
			case "__array_alloc_f64": 8;
			case "__array_alloc_i32", "__array_alloc_bool", "__array_alloc_ref", "__array_alloc_bytes": 4;
			default: null;
		};

	static function hasFunction(program:IrProgram, name:String):Bool {
		for (fn in program.functions)
			if (fn.name == name)
				return true;
		return false;
	}

	static function hasExceptions(program:IrProgram):Bool {
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

	static function reachableFunctions(program:IrProgram, entry:String, ?additionalRoots:Array<String>):Map<String, Bool> {
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
			I32Const(typeId(F64)),
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
			I32Const(typeId(Bytes)),
			I32Eq,
			If(null),
			LocalGet(0),
			LocalGet(1),
			Call(stringEqual),
			LocalSet(2),
			Else,
			LocalGet(3),
			I32Const(typeId(I32)),
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
			I32Const(typeId(Bool)),
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
			I32Const(typeId(F64)),
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
			I32Const(typeId(I64)),
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

	static function programFunction(program:IrProgram, name:String):IrFunction {
		for (fn in program.functions)
			if (fn.name == name)
				return fn;
		throw 'Unknown IR function "$name"';
	}

	static function resultTypes(type:IrType):Array<WasmValueType>
		return type == Void ? [] : [requireValueType(type)];

	static function requiredStringOffset(strings:Map<String, Int>, value:String):Int {
		var offset = strings.get(value);
		if (offset == null)
			throw 'Missing Wasm string data for "$value"';
		return offset;
	}

	static function requiredGlobal(globals:Map<String, Int>, name:String):Int {
		if (!globals.exists(name))
			throw 'Unknown Wasm global "$name"';
		return globals.get(name);
	}

	static function requiredFunctionIndex(functions:Map<String, Int>, name:String):Int {
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
	static var activeRepresentation:WasmRepresentation;
	static var activeTableSlots:Map<String, Int>;
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

	static function requiredLocal(locals:Map<Int, Int>, valueId:Int):Int {
		if (!locals.exists(valueId))
			throw 'Unknown Wasm local for value $valueId';
		return locals.get(valueId);
	}

	static function elidedDynamicArrayCasts(fn:IrFunction, representation:WasmRepresentation):Map<Int, IrValue> {
		// A GC Array<Dynamic> wrapper cannot cast an element-typed array wrapper. When
		// flow narrowing is immediately erased again, preserve the original anyref.
		var result:Map<Int, IrValue> = [];
		if (!Std.isOfType(representation, WasmGcRepresentation))
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
			program:IrProgram, representation:WasmRepresentation):WasmFunction {
		activeProgram = program;
		activeRepresentation = representation;
		activeTableSlots = tableSlots;
		activeElidedDynamicArrayCasts = elidedDynamicArrayCasts(fn, representation);
		var analysis = new WasmCfgAnalysis(fn),
			placement = new WasmValuePlacement(fn, representation),
			valueLocals = placement.values,
			locals = placement.locals;
		representation.beginFunction(function(type) return placement.allocate(type), exceptionTag);
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
				exception: placement.allocate(activeRepresentation.valueType(Dyn)),
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
				var exceptionLocal = placement.allocate(activeRepresentation.valueType(Dyn)),
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
		return exceptionState == null ? [Unreachable] : activeRepresentation.zeroValue(Dyn).concat([Throw(exceptionState.tag)]);
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
				emit(body, activeRepresentation.nullValue(output.type, requiredLocal(values, output.id)));
			case ConstVoid(_):
			case TypeValue(output, type):
				emit(body, [I32Const(typeId(type)), LocalSet(requiredLocal(values, output.id))]);
			case ToDyn(output, value):
				var original = activeElidedDynamicArrayCasts.get(value.id),
					dynamicValue = original == null ? value : original,
					represented = activeRepresentation.toDynamic(dynamicValue, requiredLocal(values, output.id), requiredLocal(values, dynamicValue.id));
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
					var represented = activeRepresentation.safeCast(output, value, requiredLocal(values, output.id), requiredLocal(values, value.id));
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
				var represented = activeRepresentation.staticClosure(name, activeTableSlots, requiredLocal(values, output.id));
				if (represented != null)
					emit(body, represented);
				else
					emit(body, [I32Const(tableSlot * 2 + 1), LocalSet(requiredLocal(values, output.id))]);
			case CallClosure(output, closure, arguments):
				var typeInfo = closureTypes.get(Std.string(closure.type));
				if (typeInfo == null)
					throw 'Wasm closure type ${Std.string(closure.type)} has no indirect signature';
				var instanceType = typeInfo.instanceType,
					destination = output.type == Void ? -1 : requiredLocal(values, output.id),
					represented = activeRepresentation.callClosure(typeInfo.staticType, instanceType, arguments, requiredLocal(values, closure.id),
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
				var represented = activeRepresentation.instanceClosure(name, activeTableSlots, requiredLocal(values, receiver.id),
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
				var represented = activeRepresentation.toVirtual(value, requiredLocal(values, output.id), requiredLocal(values, value.id));
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
							represented = targets.length == 0 ? null : activeRepresentation.virtualCall(output, object, arguments, targets,
								requiredLocal(values, object.id), output.type == Void ? -1 : requiredLocal(values, output.id),
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
						var represented = activeRepresentation.virtualCall(output, object, arguments, targets, requiredLocal(values, object.id),
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
				var represented = activeRepresentation.constantString(value, requiredLocal(values, output.id), strings);
				if (represented != null)
					emit(body, represented);
				else {
					var pointer = strings.get(value);
					if (pointer == null)
						throw 'Wasm string literal was not placed in a data segment';
					emit(body, [I32Const(pointer), LocalSet(requiredLocal(values, output.id))]);
				}
			case MakeEnum(output, typeName, constructor, arguments):
				var represented = activeRepresentation.makeEnum(typeName, constructor, arguments, requiredLocal(values, output.id),
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
				var represented = activeRepresentation.enumIndex(value, requiredLocal(values, output.id), requiredLocal(values, value.id));
				if (represented != null)
					emit(body, represented);
				else
					emit(body, [
						LocalGet(requiredLocal(values, value.id)),
						I32Load(WasmLayout.HEADER_SIZE),
						LocalSet(requiredLocal(values, output.id))
					]);
			case EnumField(output, value, constructor, field):
				var represented = activeRepresentation.enumField(value, constructor, field, requiredLocal(values, output.id), requiredLocal(values, value.id));
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
				emit(body, activeRepresentation.newObject(typeName, requiredLocal(values, output.id)));
			case FieldGet(output, object, fieldName):
				emit(body, activeRepresentation.fieldGet(object, fieldName, requiredLocal(values, output.id), requiredLocal(values, object.id)));
			case FieldSet(object, fieldName, value):
				emit(body, activeRepresentation.fieldSet(object, fieldName, requiredLocal(values, object.id), requiredLocal(values, value.id)));
			case ArrayGet(output, array, index):
				var represented = activeRepresentation.arrayGet(array, index, requiredLocal(values, output.id), requiredLocal(values, array.id),
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
				var represented = activeRepresentation.arraySet(array, index, value, requiredLocal(values, array.id), requiredLocal(values, index.id),
					requiredLocal(values, value.id));
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
				var represented = activeRepresentation.arraySize(array, requiredLocal(values, output.id), requiredLocal(values, array.id));
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
					represented = activeRepresentation.iteratorNew(array, iteratorLocal, requiredLocal(values, array.id));
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
					represented = activeRepresentation.iteratorHasNext(iterator, requiredLocal(values, output.id), iteratorLocal);
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
					represented = activeRepresentation.iteratorNext(iterator, output, requiredLocal(values, output.id), iteratorLocal);
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
				binary(body, output, left, right, values, arithmeticInstruction(left.type, I32Shl, I64Shl, I32Shl));
			case ShiftRight(output, left, right):
				binary(body, output, left, right, values, arithmeticInstruction(left.type, I32ShrS, I64ShrS, I32ShrS));
			case UnsignedShiftRight(output, left, right):
				binary(body, output, left, right, values, arithmeticInstruction(left.type, I32ShrU, I64ShrU, I32ShrU));
			case Less(output, left, right):
				binary(body, output, left, right, values, comparisonInstruction(left.type, F64Lt, I64LtS, I32LtS));
			case LessEqual(output, left, right):
				binary(body, output, left, right, values, comparisonInstruction(left.type, F64Le, I64LeS, I32LeS));
			case Equal(output, left, right):
				emit(body,
					activeRepresentation.equal(requiredLocal(values, output.id), left, right, requiredLocal(values, left.id), requiredLocal(values, right.id)));
			case Call(output, name, arguments):
				var runtimeName = name;
				for (native in activeProgram.natives)
					if (native.name == name)
						runtimeName = native.symbol;
				var outputLocal = output.type == Void ? -1 : requiredLocal(values, output.id),
					represented = activeRepresentation.lowerRuntimeCall(runtimeName, output, arguments, outputLocal,
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
				if (native.result == ManagedBytes && native.pointerLength != null) {
					var lengthNative:Null<IrCNative> = null;
					for (candidate in activeProgram.cNatives)
						if (candidate.symbol == native.pointerLength)
							lengthNative = candidate;
					if (lengthNative != null) {
						var importedLength = functions.get(lengthNative.name);
						if (importedLength != null)
							pointerLengthImportIndex = importedLength;
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
					represented = activeRepresentation.lowerCNativeCall(native, arguments, outputLocal,
						[for (argument in arguments) requiredLocal(values, argument.id)], importIndex, pointerLengthImportIndex, pointerReleaseImportIndex);
				if (represented != null)
					emit(body, represented);
				else {
					for (argument in arguments)
						nativeArgument(body, argument, values);
					body.push(Call(importIndex));
					if (output.type != Void)
						body.push(LocalSet(requiredLocal(values, output.id)));
				}
		}
	}

	static function lowerInt64Native(body:Array<WasmInstruction>, output:IrValue, name:String, arguments:Array<IrValue>, values:Map<Int, Int>):Bool {
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

	static function nativeArgument(body:Array<WasmInstruction>, argument:IrValue, values:Map<Int, Int>):Void {
		body.push(LocalGet(requiredLocal(values, argument.id)));
		switch argument.type {
			case Bytes, ManagedBytes, Abstract("realtime_bytes"):
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
			case Phi(output, _), ConstVoid(output), ConstInt(output, _), ConstFloat(output, _), ConstString(output, _), ConstBool(output, _),
				ConstNull(output), TypeValue(output, _), ToDyn(output, _), IntToFloat(output, _), IntToInt64(output, _), FloatToInt(output, _),
				SafeCast(output, _), Catch(output), GlobalGet(output, _), Add(output, _, _), Sub(output, _, _), Mul(output, _, _), Div(output, _, _),
				Mod(output, _, _), BitAnd(output, _, _), BitXor(output, _, _), BitOr(output, _, _), ShiftLeft(output, _, _), ShiftRight(output, _, _),
				UnsignedShiftRight(output, _, _), Less(output, _, _), LessEqual(output, _, _), Equal(output, _, _), Call(output, _, _),
				CNativeCall(output, _, _), StaticClosure(output, _), InstanceClosure(output, _, _), CallClosure(output, _, _), ToVirtual(output, _),
				MethodCall(output, _, _, _), NewObject(output, _), FieldGet(output, _, _), ArrayGet(output, _, _), ArraySize(output, _),
				IteratorNew(output, _), IteratorHasNext(output, _), IteratorNext(output, _), MakeEnum(output, _, _, _), EnumIndex(output, _),
				EnumField(output, _, _, _): output;
			case BeginTry(_, _), EndTry(_), GlobalSet(_, _), FieldSet(_, _, _), ArraySet(_, _, _): null;
		};
}
