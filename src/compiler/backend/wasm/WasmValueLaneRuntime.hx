package compiler.backend.wasm;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.IrValueLaneRuntime;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;

/** Link the portable lane policy before the representation-specific storage and Dynamic array paths. */
class WasmValueLaneRuntime {
	public static function attach(program:IrProgram, reachable:Map<String, Bool>, used:Map<String, Bool>):Void {
		var needed = false;
		for (native in program.natives) if (used.exists(native.name) && StringTools.startsWith(native.symbol, "__value_array_")) needed = true;
		if (!needed) return;
		for (fn in program.functions) if (StringTools.startsWith(fn.name, IrValueLaneRuntime.PREFIX)) throw "Lane runtime linked twice";
		// Keep existing Wasm backing-lane sizes: sparse requests need no geometric over-reservation.
		var policy = IrValueLaneRuntime.program(false);
		program.functions = program.functions.concat(policy.functions);
		program.natives = program.natives.concat(policy.natives);
		for (fn in policy.functions) reachable.set(fn.name, true);
		for (native in policy.natives) used.set(native.name, true);
	}

	/** Runtime callers need these indices before ordinary program functions are declared. */
	public static function declare(module:WasmModule, functions:Map<String, Int>, program:IrProgram, type:IrFunction->WasmFunctionType):Void {
		for (fn in program.functions) if (StringTools.startsWith(fn.name, IrValueLaneRuntime.PREFIX))
			functions.set(fn.name, module.addFunction(new WasmFunction(fn.name, type(fn))));
	}

	public static function operation(symbol:String):Null<String> return switch symbol {
		case "__value_array_ensure": "ensure";
		case "__value_array_clear": "clear-element";
		case "__value_array_resize": "resize";
		case "__value_array_insert_empty": "insert";
		case "__value_array_remove_at": "remove-at";
		case "__value_array_reverse": "reverse";
		case "__value_array_copy": "copy";
		case "__value_array_slice": "slice";
		case "__value_array_concat": "concat";
		case "__value_array_splice": "splice";
		default: null;
	};

	public static function bind(functions:Map<String, Int>, native:IrNative):Bool {
		var name = operation(native.symbol);
		if (name == null) return false;
		functions.set(native.name, WasmModuleSupport.requiredFunctionIndex(functions, IrValueLaneRuntime.PREFIX + name));
		return true;
	}
}
