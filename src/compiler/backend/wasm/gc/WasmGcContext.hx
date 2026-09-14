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

	public function new(module:WasmModule, plan:WasmGcTypePlan, functions:Map<String, Int>, globals:Map<String, Int>, methods:Map<String, String>) {
		this.module = module;
		this.plan = plan;
		this.functions = functions;
		this.globals = globals;
		this.methods = methods;
	}
}
