package compiler.backend.wasm.gc;

import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.IrFunction;

/** State whose lifetime is limited to one native Wasm GC function lowering. */
class WasmGcFunctionContext {
	public final gc:WasmGcContext;
	// Generated runtime helpers can have a lowering context without a source IrFunction.
	public final irFunction:Null<IrFunction>;
	public final exceptionTag:Null<Int>;
	public final allocateLocal:WasmValueType->Int;

	public final arrayReferenceLocals:Map<String, Int> = [];
	public var requiredArrayLengthLocal:Null<Int>;
	public var arrayCapacityLocal:Null<Int>;
	public final functionStringConstants:Map<Int, String> = [];

	public function new(gc:WasmGcContext, irFunction:Null<IrFunction>, exceptionTag:Null<Int>, allocateLocal:WasmValueType->Int) {
		this.gc = gc;
		this.irFunction = irFunction;
		this.exceptionTag = exceptionTag;
		this.allocateLocal = allocateLocal;

		if (irFunction != null)
			for (block in irFunction.blocks)
				for (located in block.instructions)
					switch located.value {
						case ConstString(output, value):
							functionStringConstants.set(output.id, value);
						case _:
					}
	}
}
