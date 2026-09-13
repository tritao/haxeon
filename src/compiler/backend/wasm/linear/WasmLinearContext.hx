package compiler.backend.wasm.linear;

import compiler.backend.Backend.BackendOptions;
import compiler.ir.Ir.IrProgram;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmModule.WasmModule;

/** Shared state used while generating the Linear32 runtime functions. */
class WasmLinearContext {
	public final module:WasmModule;
	public final program:IrProgram;
	public final layout:WasmLayout;
	public final options:BackendOptions;

	public var functions:Map<String, Int> = [];
	public var globals:Map<String, Int> = [];
	public var rootGlobals:Array<Int> = [];
	public var strings:Map<String, Int> = [];

	public var heapStart:Int = 0;
	public var heapTop:Int = -1;
	public var rootBase:Int = 0;
	public var rootTop:Int = -1;
	public var rootFrameTop:Int = -1;
	public var rootLimit:Int = 0;
	public var freeHead:Int = -1;
	public var markStackTop:Int = -1;
	public var gcBudget:Int = -1;

	public var allocationCount:Int = -1;
	public var allocationBytes:Int = -1;
	public var largestAllocation:Int = -1;
	public var collectionCount:Int = -1;

	public var markFunction:Int = -1;
	public var traceFunction:Int = -1;
	public var collectorFunction:Int = -1;
	public var allocatorFunction:Int = -1;
	public var ryuTableBase:Int = -1;
	public var exceptionTag:Null<Int> = null;

	public function new(module:WasmModule, program:IrProgram, layout:WasmLayout, options:BackendOptions) {
		this.module = module;
		this.program = program;
		this.layout = layout;
		this.options = options;
	}
}
