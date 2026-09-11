package compiler.backend.wasm;

import compiler.backend.wasm.WasmModule.WasmLocal;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.ir.Ir.IrType;
import compiler.ir.IrFunction;
import compiler.ir.IrOperands;

/** First value-placement pass: stable SSA values become coalescible Wasm locals. */
class WasmValuePlacement {
	public final values:Map<Int, Int> = [];
	public final locals:Array<WasmLocal> = [];

	var nextLocal:Int;

	public function new(fn:IrFunction) {
		for (index in 0...fn.arguments.length)
			values.set(fn.arguments[index].id, index);
		nextLocal = fn.arguments.length;
		for (block in fn.blocks)
			for (located in block.instructions) {
				var output = IrOperands.output(located.value);
				if (output == null || output.type == Void || values.exists(output.id))
					continue;
				values.set(output.id, nextLocal++);
				locals.push({type: WasmBackend.requireValueType(output.type)});
			}
	}

	public function allocate(type:WasmValueType):Int {
		var result = nextLocal++;
		locals.push({type: type});
		return result;
	}

	public function local(valueId:Int):Int {
		if (!values.exists(valueId))
			throw 'Wasm value $valueId has no placement';
		return values.get(valueId);
	}
}
