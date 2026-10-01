package compiler.backend.wasm.gc;

import compiler.backend.wasm.gc.WasmGcTypePlan;
import compiler.backend.wasm.WasmModule.WasmModule;

/** Module-lifetime configuration and indices for native Wasm GC lowering. */
class WasmGcContext {
	public final module:WasmModule;
	public final plan:WasmGcTypePlan;

	public final functions:Map<String, Int>;
	public final globals:Map<String, Int>;
	public final methods:Map<String, String>;

	final stringSegments:Map<String, Int> = [];

	public function new(module:WasmModule, plan:WasmGcTypePlan, functions:Map<String, Int>, globals:Map<String, Int>, methods:Map<String, String>) {
		this.module = module;
		this.plan = plan;
		this.functions = functions;
		this.globals = globals;
		this.methods = methods;
	}

	/** The passive data segment holding a string literal's UTF-8 bytes, shared by every use of that literal. */
	public function stringSegment(value:String):Int {
		var segment = stringSegments.get(value);
		if (segment == null) {
			segment = module.data.length;
			module.data.push({offset: 0, bytes: haxe.io.Bytes.ofString(value), passive: true});
			stringSegments.set(value, segment);
		}
		return segment;
	}
}
