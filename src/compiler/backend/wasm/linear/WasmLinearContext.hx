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
	final rootBase:Int;
	final rootTop:Int;
	final rootFrameTop:Int;
	final rootLimit:Int;
	final markStackTop:Int;
	final heapState:Int;

	/** Where the reflection table lives, how many rows it has, and its bytes (WasmLinearReflection). */
	final reflectionTable:Int;

	final reflectionCount:Int;
	final reflectionBytes:Null<haxe.io.Bytes>;
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
	public final rootBase:Int;
	public final rootTop:Int;
	public final rootFrameTop:Int;
	public final rootLimit:Int;
	public final markStackTop:Int;

	/** Address of the C runtime's hx_heap (WasmLayout.HEAP_STATE_*). */
	public final heapState:Int;

	public final reflectionTable:Int;
	public final reflectionCount:Int;
	public final reflectionBytes:Null<haxe.io.Bytes>;

	public var markFunction:Int = -1;
	public var traceFunction:Int = -1;
	public var collectorFunction:Int = -1;
	public var heapAllocFunction:Int = -1;
	public var heapSweepFunction:Int = -1;
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
		rootBase = state.rootBase;
		rootTop = state.rootTop;
		rootFrameTop = state.rootFrameTop;
		rootLimit = state.rootLimit;
		markStackTop = state.markStackTop;
		heapState = state.heapState;
		reflectionTable = state.reflectionTable;
		reflectionCount = state.reflectionCount;
		reflectionBytes = state.reflectionBytes;
	}
}
