package compiler.backend.wasm;

import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.core.InternalError;
import compiler.ir.model.Ir.IrProgram;

/** Object-model-neutral C kernels linked through the existing C ABI, on both browser backends. */
class WasmCryptoRuntime {
	public static inline var LIBRARY = "haxeon_crypto";

	/** Links the kernels `program` uses from the runtime in the standard library at `standardLibrary` (`BackendOptions`). */
	public static function link(module:WasmModule, functions:Map<String, Int>, program:IrProgram,
			used:Map<String, Bool>, standardLibrary:Null<String>, ?fuelChargeFunction:Int):Void {
		var needed = [
			for (native in program.cNatives)
				if (native.library == LIBRARY && used.exists(native.name)) native
		];
		if (needed.length == 0)
			return;
		var runtimeBytes = WasmRuntimeLinker.shipped(standardLibrary,
			fuelChargeFunction == null ? "crypto-runtime.wasm" : "crypto-runtime-neutral.wasm");
		var exports = WasmRuntimeLinker.link(module, runtimeBytes, name -> switch name {
			case "fuel_charge" if (fuelChargeFunction != null): fuelChargeFunction;
			default: throw new InternalError('Unexpected crypto guest import "$name"');
		}, fuelChargeFunction);
		for (native in needed) {
			var index = exports.get(native.symbol);
			if (index == null)
				throw new InternalError('Unknown built-in crypto kernel "${native.symbol}"');
			var type = module.functionType(index);
			if (native.symbol != "haxeon_sha256" || type.parameters.length != 6 || type.results.length != 0)
				throw new InternalError('Invalid crypto kernel signature "${native.symbol}"');
			for (parameter in type.parameters)
				if ((switch (parameter) {
					case compiler.backend.wasm.WasmTypes.WasmValueType.I32: false;
					default: true;
				}))
					throw new InternalError('Invalid crypto kernel argument "${native.symbol}"');
			functions.set(native.name, index);
		}
	}
}
