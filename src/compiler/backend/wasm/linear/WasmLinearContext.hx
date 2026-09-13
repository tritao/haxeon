package compiler.backend.wasm.linear;

import compiler.backend.Backend.BackendOptions;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.ir.Ir.IrProgram;

/** Fully prepared module state used while generating Linear32 runtime functions. */
typedef WasmLinearContextState = {
	final functions:Map<String, Int>;
	final globals:Map<String, Int>;
	final rootGlobals:Array<Int>;
	final strings:Map<String, Int>;
	final heapStart:Int;
	final heapTop:Int;
	final rootBase:Int;
	final rootTop:Int;
	final rootFrameTop:Int;
	final rootLimit:Int;
	final freeHead:Int;
	final markStackTop:Int;
	final gcBudget:Int;
	final allocationCount:Int;
	final allocationBytes:Int;
	final largestAllocation:Int;
	final collectionCount:Int;
}

/** Shared state used while generating the Linear32 runtime functions. */
class WasmLinearContext {
	public final module:WasmModule;
	public final program:IrProgram;
	public final layout:WasmLayout;
	public final options:BackendOptions;

	public final functions:Map<String, Int>;
	public final globals:Map<String, Int>;
	public final rootGlobals:Array<Int>;
	public final strings:Map<String, Int>;

	public final heapStart:Int;
	public final heapTop:Int;
	public final rootBase:Int;
	public final rootTop:Int;
	public final rootFrameTop:Int;
	public final rootLimit:Int;
	public final freeHead:Int;
	public final markStackTop:Int;
	public final gcBudget:Int;

	public final allocationCount:Int;
	public final allocationBytes:Int;
	public final largestAllocation:Int;
	public final collectionCount:Int;

	public var markFunction:Int = -1;
	public var traceFunction:Int = -1;
	public var collectorFunction:Int = -1;
	public var allocatorFunction:Int = -1;
	public var exceptionTag:Null<Int> = null;

	public function new(module:WasmModule, program:IrProgram, layout:WasmLayout, options:BackendOptions, state:WasmLinearContextState) {
		this.module = module;
		this.program = program;
		this.layout = layout;
		this.options = options;
		functions = state.functions;
		globals = state.globals;
		rootGlobals = state.rootGlobals;
		strings = state.strings;
		heapStart = state.heapStart;
		heapTop = state.heapTop;
		rootBase = state.rootBase;
		rootTop = state.rootTop;
		rootFrameTop = state.rootFrameTop;
		rootLimit = state.rootLimit;
		freeHead = state.freeHead;
		markStackTop = state.markStackTop;
		gcBudget = state.gcBudget;
		allocationCount = state.allocationCount;
		allocationBytes = state.allocationBytes;
		largestAllocation = state.largestAllocation;
		collectionCount = state.collectionCount;
	}
}
