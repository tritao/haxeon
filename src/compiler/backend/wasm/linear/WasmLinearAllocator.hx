package compiler.backend.wasm.linear;

import compiler.backend.wasm.WasmFunctionBuilder.WasmFunctionBuilder;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;

/**
 * `__haxeon_alloc(size)`, which generated code calls for every heap block. Allocation is the linked C runtime's
 * (native/wasm/heap.c); this passes it the module's heap state.
 */
class WasmLinearAllocator {
	public static function build(context:WasmLinearContext):Int {
		var type:WasmFunctionType = {parameters: [I32], results: [I32]},
			builder = new WasmFunctionBuilder("__haxeon_alloc", type),
			index = builder.register(context.module),
			requestedSize = builder.parameter("requestedSize", 0);
		builder.i32Const(context.heapState);
		builder.localGet(requestedSize);
		builder.call(builder.functionRef(context.heapAllocFunction));
		builder.return_();
		context.module.setFunction(index, builder.finish());
		context.allocatorFunction = index;
		return index;
	}
}
