package compiler.backend.wasm.linear;

import compiler.backend.Backend.BackendOptions;
import compiler.backend.Backend.BackendResult;
import compiler.backend.MemoryContract.MemoryContract;
import compiler.backend.MemoryContract.MemoryContractCodec;
import compiler.backend.wasm.WasmModuleSupport.WasmClosureTypes;
import compiler.backend.wasm.WasmFunctionLower;
import compiler.backend.wasm.WasmEncoder;
import compiler.backend.wasm.gc.WasmGcRoots;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmPatch;
import compiler.backend.wasm.linear.WasmLinearRepresentation;
import compiler.backend.wasm.WasmRepresentation.WasmRepresentationSet;
import compiler.backend.wasm.WasmTarget.WasmTargetConfig;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.linear.WasmLinearAllocator;
import compiler.backend.wasm.linear.WasmLinearArrays;
import compiler.backend.wasm.linear.WasmLinearContext;
import compiler.backend.wasm.linear.WasmLinearContext.WasmLinearContextState;
import compiler.backend.wasm.linear.WasmLinearGc;
import compiler.backend.wasm.linear.WasmLinearRuntime;
import compiler.ir.Ir.IrProgram;
import compiler.ir.IrVerifier;

/** Owns construction and lowering of a complete Linear32 Wasm module. */
class WasmLinearModuleBuilder {
	final program:IrProgram;
	final options:BackendOptions;
	final patchChanged:Null<Array<String>>;
	final target:WasmTargetConfig;
	final module:WasmModule;

	var importMemory:Bool;
	var contract:Null<MemoryContract>;
	var exportedFunctions:Array<String>;
	var preferredEntry:String;
	var reachable:Map<String, Bool>;
	var usedCNatives:Map<String, Bool>;
	var usedNatives:Map<String, Bool>;
	var layout:WasmLayout;
	var strings:Map<String, Int>;
	var rootBase:Int;
	var rootTop:Int;
	var rootFrameTop:Int;
	var rootLimit:Int;
	var heapStart:Int;
	var heapTop:Int;
	var freeHead:Int;
	var markStackTop:Int;
	var gcBudget:Int;
	var allocationCount:Int;
	var allocationBytes:Int;
	var largestAllocation:Int;
	var collectionCount:Int;
	var rootGlobals:Array<Int>;
	var functions:Map<String, Int>;
	var globals:Map<String, Int>;
	var linear:WasmLinearContext;
	var allocator:Int;
	var runtimeFunctionCount:Int;
	var methods:Map<String, String>;
	var staticDataAddresses:Map<String, Int>;
	var closureTypes:Map<String, WasmClosureTypes>;
	var representation:WasmRepresentationSet;
	var tableSlots:Map<String, Int>;
	var exceptionTag:Null<Int>;

	public function new(program:IrProgram, options:BackendOptions, patchChanged:Null<Array<String>>, target:WasmTargetConfig) {
		this.program = program;
		this.options = options;
		this.patchChanged = patchChanged;
		this.target = target;
		module = new WasmModule(target.debugNames ? "haxeon" : null);
	}

	public static function compile(program:IrProgram, options:BackendOptions, patchChanged:Null<Array<String>>, target:WasmTargetConfig):BackendResult {
		return new WasmLinearModuleBuilder(program, options, patchChanged, target).compileModule();
	}

	function compileModule():BackendResult {
		IrVerifier.verify(program);
		prepareModule();
		buildRuntime();
		declareFunctions();
		var gcRootMetadata = lowerFunctions();
		publishMetadata(gcRootMetadata);
		finalizeExports();
		return {target: options.target, bytes: WasmEncoder.encode(module)};
	}

	function prepareModule():Void {
		importMemory = options.importMemory == true;
		contract = options.memoryContract;
		var memoryBase = contract == null ? (options.memoryBase == null ? 0 : options.memoryBase) : contract.guestBase;
		exportedFunctions = options.exports == null ? [] : options.exports;
		if (contract != null) {
			if (!importMemory)
				throw "A Wasm memory contract requires imported memory";
			MemoryContractCodec.validate(contract);
		}
		if (memoryBase < 0 || (memoryBase & 7) != 0)
			throw 'Wasm memory base must be a non-negative 8-byte-aligned value, got $memoryBase';
		module.importMemory = importMemory;
		preferredEntry = WasmModuleSupport.hasFunction(program,
			"main") ? "main" : WasmModuleSupport.hasFunction(program, "Main.main") ? "Main.main" : program.entryPoint;
		var roots = exportedFunctions.copy();
		if (WasmModuleSupport.hasFunction(program, "__init"))
			roots.push("__init");
		reachable = WasmModuleSupport.reachableFunctionsWithGeneratedRuntimeRoots(program, preferredEntry, roots);
		usedCNatives = WasmModuleSupport.reachableCNatives(program, reachable);
		usedNatives = WasmModuleSupport.reachableNatives(program, reachable);
		layout = new WasmLayout(program);
		strings = [];
		var nextData = memoryBase + WasmLayout.STRING_DATA_OFFSET;
		for (fn in program.functions)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case ConstString(_, value):
							if (!strings.exists(value)) {
								var bytes = WasmModuleSupport.stringBytes(value);
								var offset = nextData;
								module.data.push({offset: offset, bytes: bytes});
								strings.set(value, offset);
								nextData = WasmModuleSupport.align(offset + bytes.length, 8);
							}
						default:
					}
		for (value in ["null", "true", "false", "Object"].concat(WasmLinearRuntime.dynamicStringConstants(program))
			.concat(WasmLinearDynamicArrays.runtimeStrings(program)))
			if (!strings.exists(value)) {
				var bytes = WasmModuleSupport.stringBytes(value),
					offset = nextData;
				module.data.push({offset: offset, bytes: bytes});
				strings.set(value, offset);
				nextData = WasmModuleSupport.align(offset + bytes.length, 8);
			}
		var staticData = WasmModuleSupport.placeStaticData(program, module, nextData, reachable);
		nextData = staticData.end;
		staticDataAddresses = staticData.addresses;
		module.memoryMin = 1;
		module.exportMemory = !importMemory;
		rootBase = WasmModuleSupport.align(Std.int(Math.max(1024, nextData)), 8);
		var rootReserve = WasmLayout.ROOT_RESERVE;
		rootLimit = rootBase + rootReserve;
		heapStart = rootLimit;
		if (contract != null && heapStart > contract.guestLimit)
			throw 'Wasm guest layout exceeds memory contract guest limit ${contract.guestLimit}';
		module.memoryMin = contract == null ? WasmModuleSupport.memoryPages(heapStart) : WasmModuleSupport.memoryPages(contract.memorySize);
		heapTop = module.globals.length;
		module.globals.push({type: I32, mutable: true, init: [I32Const(heapStart)]});
		rootTop = module.globals.length;
		module.globals.push({type: I32, mutable: true, init: [I32Const(rootBase)]});
		rootFrameTop = module.globals.length;
		module.globals.push({type: I32, mutable: true, init: [I32Const(0)]});
		freeHead = module.globals.length;
		module.globals.push({type: I32, mutable: true, init: [I32Const(0)]});
		markStackTop = module.globals.length;
		module.globals.push({type: I32, mutable: true, init: [I32Const(0)]});
		gcBudget = -1;
		if (options.wasmGcStress != true) {
			gcBudget = module.globals.length;
			module.globals.push({type: I32, mutable: true, init: [I32Const(WasmLayout.GC_MIN_ALLOCATION_BUDGET)]});
		}
		allocationCount = -1;
		allocationBytes = -1;
		largestAllocation = -1;
		collectionCount = -1;
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
		globals = [];
		rootGlobals = [];
		for (field in program.staticFields) {
			globals.set(field.name, module.globals.length);
			module.globals.push({type: WasmModuleSupport.requireValueType(field.type), mutable: true, init: WasmModuleSupport.zeroValue(field.type)});
			if (WasmTarget.isReference(field.type))
				rootGlobals.push(WasmModuleSupport.requiredGlobal(globals, field.name));
		}
		functions = [];
		var linearState:WasmLinearContextState = {
			functions: functions,
			globals: globals,
			rootGlobals: rootGlobals,
			strings: strings,
			heapStart: heapStart,
			heapTop: heapTop,
			rootBase: rootBase,
			rootTop: rootTop,
			rootFrameTop: rootFrameTop,
			rootLimit: rootLimit,
			freeHead: freeHead,
			markStackTop: markStackTop,
			gcBudget: gcBudget,
			allocationCount: allocationCount,
			allocationBytes: allocationBytes,
			largestAllocation: largestAllocation,
			collectionCount: collectionCount
		};
		linear = new WasmLinearContext(module, program, layout, options, linearState);
	}

	function buildRuntime():Void {
		WasmModuleSupport.addCNativeImports(module, functions, program, usedCNatives);
		WasmLinearRuntime.addImports(linear, usedNatives);
		WasmLinearGc.build(linear);
		allocator = WasmLinearAllocator.build(linear);
		functions.set("__haxeon_alloc", allocator);
		WasmLinearRuntime.register(linear);
		WasmLinearArrays.registerNativeAllocators(linear);
		WasmLinearDynamicArrays.register(linear);
		runtimeFunctionCount = module.functions.length;
	}

	function declareFunctions():Void {
		methods = [];
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
					parameters.push(WasmModuleSupport.requireValueType(argument.type))
				catch (error:Dynamic)
					throw 'Wasm function ${fn.name} has an unsupported parameter type: $error';
			var results:Array<WasmValueType> = [];
			try
				results = WasmModuleSupport.resultTypes(fn.result)
			catch (error:Dynamic)
				throw 'Wasm function ${fn.name} has an unsupported result type: $error';
			var type:WasmFunctionType = {parameters: parameters, results: results};
			functions.set(fn.name, module.addFunction(new WasmFunction(fn.name, type)));
		}
		closureTypes = WasmModuleSupport.collectClosureTypes(module, program);
		var bytesDataPointer = functions.get("__haxeon_bytes_data_pointer");
		if (bytesDataPointer == null)
			throw "Linear Wasm bytes data pointer helper is missing";
		var linearRepresentation = new WasmLinearRepresentation(layout, allocator, bytesDataPointer);
		representation = new WasmRepresentationSet(linearRepresentation, linearRepresentation, null, linearRepresentation, null);
		tableSlots = WasmModuleSupport.buildTableSlots(module, functions);
		var exceptionTagType:Null<Int> = WasmModuleSupport.hasExceptions(program) ? module.typeIndex({
			parameters: [I32],
			results: []
		}) : null; // The module declares one tag; instruction immediates use its tag index, not this type index.
		exceptionTag = exceptionTagType == null ? null : 0;
		module.exceptionTagType = exceptionTagType;
		linear.exceptionTag = exceptionTag;
		WasmLinearRuntime.finalizeDynamicString(linear);
		WasmLinearGc.wrapRuntimeFunctions(linear, runtimeFunctionCount);
		module.exportTable = module.tableMin != null;
	}

	function lowerFunctions():haxe.io.Bytes {
		return WasmGcRoots.encodeAndVisit(program, function(fn, rootPoints) {
			if (!reachable.exists(fn.name) || (fn.name == "__entry" && preferredEntry != "__entry"))
				return;
			var functionIndex = WasmModuleSupport.requiredFunctionIndex(functions, fn.name);
			module.setFunction(functionIndex,
				WasmFunctionLower.lower(module, fn, functions, module.functionType(functionIndex), layout, allocator, rootTop, rootFrameTop, rootLimit,
					globals, strings, methods, closureTypes, tableSlots, exceptionTag, rootPoints, program, representation, staticDataAddresses));
		});
	}

	function publishMetadata(gcRootMetadata:haxe.io.Bytes):Void {
		module.customSections.push({name: "haxeon.gc.roots", bytes: gcRootMetadata});
		module.customSections.push({name: "haxeon.patch", bytes: WasmPatch.manifest(program, patchChanged)});
		module.customSections.push({name: "haxeon.patch.slots", bytes: WasmPatch.tableManifest(tableSlots)});
		if (contract != null)
			module.customSections.push({name: MemoryContractCodec.SECTION_NAME, bytes: MemoryContractCodec.encode(contract)});
	}

	function finalizeExports():Void {
		var entry = functions.get(preferredEntry);
		if (entry == null)
			throw 'Wasm entry point $preferredEntry was not emitted';
		if (WasmModuleSupport.hasFunction(program, "__init"))
			module.start = functions.get("__init");
		module.exports.push({name: "main", functionIndex: entry});
		for (exported in exportedFunctions) {
			var exportIndex = functions.get(exported);
			if (exportIndex == null)
				throw 'Wasm export "$exported" is not a reachable function';
			module.exports.push({name: exported, functionIndex: exportIndex});
		}
		if (options.wasmMemoryStats == true) {
			WasmModuleSupport.addMemoryStatExport(module, "haxeon.memory.heap_base", [I32Const(heapStart)]);
			WasmModuleSupport.addMemoryStatExport(module, "haxeon.memory.heap_top", [GlobalGet(heapTop)]);
			WasmModuleSupport.addMemoryStatExport(module, "haxeon.memory.root_base", [I32Const(rootBase)]);
			WasmModuleSupport.addMemoryStatExport(module, "haxeon.memory.root_top", [GlobalGet(rootTop)]);
			WasmModuleSupport.addMemoryStatExport(module, "haxeon.memory.root_limit", [I32Const(rootLimit)]);
			// Kept temporarily for hosts that still display the old metadata counters.
			// In-block headers make out-of-line GC metadata a zero-sized region.
			WasmModuleSupport.addMemoryStatExport(module, "haxeon.memory.metadata_base", [I32Const(heapStart)]);
			WasmModuleSupport.addMemoryStatExport(module, "haxeon.memory.metadata_top", [I32Const(heapStart)]);
			WasmModuleSupport.addMemoryStatExport(module, "haxeon.memory.allocation_count", [GlobalGet(allocationCount)]);
			WasmModuleSupport.addMemoryStatExport(module, "haxeon.memory.allocated_bytes", [GlobalGet(allocationBytes)]);
			WasmModuleSupport.addMemoryStatExport(module, "haxeon.memory.largest_allocation_bytes", [GlobalGet(largestAllocation)]);
			WasmModuleSupport.addMemoryStatExport(module, "haxeon.memory.collection_count", [GlobalGet(collectionCount)]);
		}
	}
}
