import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrInterpreter;
import compiler.ir.IrVerifier;
import compiler.backend.Backend.BackendTarget;
import compiler.backend.hl.HlBackend;
import compiler.backend.wasm.WasmBackend;

class IrIntegerBuilderMain {
	static function main():Void {
		var builder = new IrBuilder();
		var remainder = builder.mod(builder.constInt(13, I64), builder.constInt(5, I64));
		var left = builder.shiftLeft(remainder, builder.constInt(4));
		var combined = builder.bitOr(left, builder.constInt(2, I64));
		var masked = builder.bitAnd(combined, builder.constInt(63, I64));
		var toggled = builder.bitXor(masked, builder.constInt(8, I64));
		var signed = builder.shiftRight(toggled, builder.constInt(1));
		var unsigned = builder.unsignedShiftRight(signed, builder.constInt(1));
		builder.returnValue(builder.add(unsigned, builder.constInt(28, I64)));
		var program = new IrProgram("main");
		program.functions = [new IrFunction("main", builder.arguments, I64, builder.blocks)];
		IrVerifier.verify(program);
		if (new IrInterpreter(program).run() != 42) throw "64-bit integer builder operations gave the wrong result";
		if (new HlBackend().compile(program, {target: HashLink, debugNames: true}).bytes.length == 0
			|| new WasmBackend().compile(program, {target: Wasm32, debugNames: true}).bytes.length == 0
			|| new WasmBackend().compile(program, {target: WasmGc, debugNames: true}).bytes.length == 0)
			throw "64-bit integer builder operations must lower on each backend";
		Sys.println("PASS: IR builder preserves integer widths through modulo, bitwise operations and shifts");
	}
}
