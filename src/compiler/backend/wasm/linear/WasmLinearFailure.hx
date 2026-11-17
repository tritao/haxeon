package compiler.backend.wasm.linear;

import compiler.backend.wasm.WasmFunctionBuilder.WasmFunctionBuilder;
import compiler.backend.wasm.WasmModuleSupport;
import compiler.core.InternalError;

/**
 * How a wasm32 module's runtime checks fail: a catchable null Haxe exception when the program can catch one (in a runtime-neutral
 * module, through the pending-exception globals), else a trap. It is the module's own, made from its context, never shared state.
 */
class WasmLinearFailure {
	final throws:Bool;
	final neutral:Bool;
	final pendingFlag:Null<Int>;
	final pendingValue:Null<Int>;

	function new(throws:Bool, neutral:Bool, pendingFlag:Null<Int>, pendingValue:Null<Int>) {
		this.throws = throws;
		this.neutral = neutral;
		this.pendingFlag = pendingFlag;
		this.pendingValue = pendingValue;
	}

	/** The failure of the module `context` builds. */
	public static function of(context:WasmLinearContext):WasmLinearFailure
		return new WasmLinearFailure(WasmModuleSupport.hasExceptions(context.program),
			context.options.wasmRuntimeNeutral == true,
			context.pendingExceptionFlag, context.pendingExceptionValue);

	/** The failure of a module whose program catches no exception: a trap. */
	public static function trapping():WasmLinearFailure
		return new WasmLinearFailure(false, false, null, null);

	/** Fails a runtime check at this point of `builder`'s function. */
	public function emit(builder:WasmFunctionBuilder):Void {
		if (throws) {
			if (neutral) {
				var flag = pendingFlag, value = pendingValue;
				if (flag == null || value == null)
					throw new InternalError("Runtime-neutral exception globals were not initialized");
				builder.i32Const(0);
				builder.emit(GlobalSet(value));
				builder.i32Const(1);
				builder.emit(GlobalSet(flag));
				for (result in builder.type.results)
					builder.emitAll(WasmLinearRuntime.zeroWasmResult(result));
				builder.return_();
			} else {
				builder.i32Const(0);
				builder.emit(Throw(0));
			}
		} else
			builder.emit(Unreachable);
	}
}
