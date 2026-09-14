package compiler.backend.wasm.gc;

import compiler.backend.wasm.WasmGcTypePlan;
import compiler.backend.wasm.WasmModule.WasmModule;

/** Module-lifetime configuration and indices for native Wasm GC lowering. */
class WasmGcContext {
	public final module:WasmModule;
	public final plan:WasmGcTypePlan;

	public final functions:Map<String, Int>;
	public final globals:Map<String, Int>;
	public final methods:Map<String, String>;

	// These module-level bridge settings move to WasmGcInterop with the ABI extraction.
	public var scratchTop(default, null):Int = -1;
	public var scratchAllocator(default, null):Int = -1;
	public final nativePointerReleaseIndices:Array<Int> = [];
	public final nativePointerReleaseBySymbol:Map<String, Int> = [];

	public function new(module:WasmModule, plan:WasmGcTypePlan, functions:Map<String, Int>, globals:Map<String, Int>, methods:Map<String, String>) {
		this.module = module;
		this.plan = plan;
		this.functions = functions;
		this.globals = globals;
		this.methods = methods;
	}

	public function configureCNativeScratch(scratchTop:Int, scratchAllocator:Int):Void {
		this.scratchTop = scratchTop;
		this.scratchAllocator = scratchAllocator;
	}

	public function configureNativePointerReleases(releases:Map<String, Int>):Void {
		for (symbol in releases.keys()) {
			var index = releases.get(symbol);
			nativePointerReleaseBySymbol.set(symbol, index);
			nativePointerReleaseIndices.push(index);
		}
		nativePointerReleaseIndices.sort((left, right) -> left - right);
	}
}
