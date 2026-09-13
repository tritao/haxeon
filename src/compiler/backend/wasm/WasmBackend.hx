package compiler.backend.wasm;

import compiler.backend.Backend;
import compiler.backend.Backend.BackendOptions;
import compiler.backend.Backend.BackendResult;
import compiler.ir.Ir.IrProgram;
import compiler.backend.wasm.WasmPatch.WasmPatchArtifact;
import compiler.backend.wasm.WasmPatch;

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
			return WasmGcModuleBuilder.compile(program, options, patchChanged);
		if (target.referenceModel == Linear32)
			return WasmLinearModuleBuilder.compile(program, options, patchChanged, target);
		throw "Wasm backend target " + Std.string(options.target) + " is not implemented yet";
	}
}
