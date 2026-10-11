package compiler.backend.wasm;

import haxe.io.Bytes;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmFunctionBuilder.WasmFunctionBuilder;

/** The versioned module contract shared by the compiler and a runtime-neutral Wasm host. */
class WasmRuntimeNeutralProfile {
	public static inline final SECTION_NAME = "haxeon.runtime.profile";
	public static inline final FUEL_MODULE = "haxeon_host";
	public static inline final FUEL_IMPORT = "fuel_charge";
	public static inline final FUEL_FUNCTION = "__haxeon_fuel_charge";

	public static function addFuelImport(module:WasmModule):Int
		return module.addImport(FUEL_MODULE, FUEL_IMPORT, {parameters: [], results: [I32]});

	/** Traps immediately when the host refuses a charge. The host call itself is the only fuel ABI. */
	public static function addFuelFunction(module:WasmModule, importIndex:Int):Int {
		var type:WasmFunctionType = {parameters: [], results: []},
			builder = new WasmFunctionBuilder(FUEL_FUNCTION, type);
		builder.emit(Call(importIndex));
		builder.emit(I32Eqz);
		builder.emit(If(null));
		builder.emit(Unreachable);
		builder.emit(End);
		return module.addFunction(builder.finish());
	}

	public static function sectionBytes():Bytes
		return Bytes.ofString('{"formatVersion":1,"profile":"haxeon.wasm.runtime-neutral","memory":"wasm32-linear","gc":"precise-roots-v1","exceptions":{"protocol":"pending-global-v1","unhandled":"unreachable"},"initialization":{"kind":"metered-start-v1","fuel":"host-initialization-budget"},"fuel":{"import":"haxeon_host.fuel_charge","parameters":[],"result":"i32","charges":["function-entry","loop-backedge"],"exhaustion":"unreachable"}}');
}
