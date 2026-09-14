package compiler.backend.wasm;

import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrValue;
import compiler.ir.IrFunction;
import compiler.backend.wasm.WasmModule.WasmLocal;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmRepresentation.WasmFunctionRepresentationContext;
import compiler.backend.wasm.WasmRepresentation.WasmRepresentationSet;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.gc.WasmGcRoots.WasmSafepoint;

typedef WasmFunctionArrayTemps = {
	final len:Int;
	final capacity:Int;
	final data:Int;
	final required:Int;
}

typedef WasmFunctionExceptionState = {
	final handler:Int;
	final exception:Int;
	final saved:Map<Int, Int>;
	final blocks:Map<Int, Int>;
	final tag:Int;
}

typedef WasmFunctionGcRootState = {
	final frame:Int;
	final top:Int;
	final frameTop:Int;
	final slots:Array<Int>;
	final slotByValue:Map<Int, Int>;
	final live:Map<Int, Map<Int, Array<Int>>>;
	final size:Int;
}

/** Invocation state that exists only while lowering one Wasm function. */
class WasmFunctionLowerContext {
	public final module:WasmModule;
	public final irFunction:IrFunction;
	public final program:IrProgram;
	public final representation:WasmRepresentationSet;
	public final tableSlots:Map<String, Int>;
	public final staticDataAddresses:Map<String, Int>;
	public final exceptionTag:Null<Int>;
	public final rootPoints:Array<WasmSafepoint>;

	public final placement:WasmValuePlacement;
	public final valueLocals:Map<Int, Int>;
	public final locals:Array<WasmLocal>;
	public final arrayTemps:WasmFunctionArrayTemps;
	public var elidedDynamicArrayCasts:Map<Int, IrValue> = [];
	public var exceptionState:Null<WasmFunctionExceptionState>;
	public var gcRootState:Null<WasmFunctionGcRootState>;

	public function new(module:WasmModule, fn:IrFunction, program:IrProgram, moduleRepresentation:WasmRepresentationSet, tableSlots:Map<String, Int>,
			staticDataAddresses:Map<String, Int>, exceptionTag:Null<Int>, rootPoints:Array<WasmSafepoint>) {
		this.module = module;
		this.irFunction = fn;
		this.program = program;
		this.tableSlots = tableSlots;
		this.staticDataAddresses = staticDataAddresses;
		this.exceptionTag = exceptionTag;
		this.rootPoints = rootPoints;

		placement = new WasmValuePlacement(fn, moduleRepresentation.values);
		valueLocals = placement.values;
		locals = placement.locals;
		var functionContext:WasmFunctionRepresentationContext = {
			allocateLocal: function(type:WasmValueType) return placement.allocate(type),
			exceptionTag: exceptionTag,
			irFunction: fn
		};
		representation = moduleRepresentation.forFunction(functionContext);
		arrayTemps = {
			len: placement.allocate(I32),
			capacity: placement.allocate(I32),
			data: placement.allocate(I32),
			required: placement.allocate(I32)
		};
	}
}
