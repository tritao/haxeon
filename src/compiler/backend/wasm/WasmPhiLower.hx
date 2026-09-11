package compiler.backend.wasm;

import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.ir.Ir.IrPhiInput;
import compiler.ir.Ir.IrValue;

/** Edge-aware phi destruction shared by structured and fallback CFG emission. */
class WasmPhiLower {
	public static function emit(body:Array<WasmInstruction>, output:IrValue, inputs:Array<IrPhiInput>, values:Map<Int, Int>, predecessor:Int):Void {
		for (input in inputs) {
			push(body, [
				WasmInstruction.LocalGet(predecessor),
				WasmInstruction.I32Const(input.block),
				WasmInstruction.I32Eq,
				WasmInstruction.If(null),
				WasmInstruction.LocalGet(values.get(input.value.id)),
				WasmInstruction.LocalSet(values.get(output.id)),
				WasmInstruction.End
			]);
		}
	}

	static function push(body:Array<WasmInstruction>, instructions:Array<WasmInstruction>):Void
		for (instruction in instructions)
			body.push(instruction);
}
