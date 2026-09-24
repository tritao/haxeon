package compiler.backend.wasm;

import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.ir.Ir.IrPhiInput;

/** Captures phi operands before any destination is overwritten on an edge. */
class WasmPhiLower {
	public static function capture(body:Array<WasmInstruction>, inputs:Array<IrPhiInput>, values:Map<Int, Int>, predecessor:Int, temporary:Int):Void {
		for (input in inputs) {
			push(body, [
				WasmInstruction.LocalGet(predecessor),
				WasmInstruction.I32Const(input.block),
				WasmInstruction.I32Eq,
				WasmInstruction.If(null),
				WasmInstruction.LocalGet(requiredLocal(values, input.value.id)),
				WasmInstruction.LocalSet(temporary),
				WasmInstruction.End
			]);
		}
	}

	static function requiredLocal(values:Map<Int, Int>, valueId:Int):Int {
		var local = values.get(valueId);
		if (local == null)
			throw 'Missing Wasm local for value $valueId';
		return local;
	}

	static function push(body:Array<WasmInstruction>, instructions:Array<WasmInstruction>):Void
		for (instruction in instructions)
			body.push(instruction);
}
