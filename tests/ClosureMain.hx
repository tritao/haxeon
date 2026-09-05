import compiler.hl.HlWriter;
import compiler.ir.HlLower;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import sys.io.File;

class ClosureMain {
	static function main():Void {
		var twiceBuilder = new IrBuilder(),
			argument = twiceBuilder.argument("value", IrType.I32),
			two = twiceBuilder.constInt(2),
			product = twiceBuilder.mul(argument, two);
		twiceBuilder.returnValue(product);

		var mainBuilder = new IrBuilder(),
			closure = mainBuilder.staticClosure("twice", IrType.Function([IrType.I32], IrType.I32)),
			input = mainBuilder.constInt(21),
			result = mainBuilder.callClosure(closure, [input], IrType.I32);
		mainBuilder.returnValue(result);

		var program = new IrProgram("__entry");
		program.natives.push({
			name: "__exit",
			library: "std",
			symbol: "sys_exit",
			arguments: [IrType.I32],
			result: IrType.Void
		});
		program.functions.push(new IrFunction("twice", twiceBuilder.arguments, IrType.I32, twiceBuilder.blocks));
		program.functions.push(new IrFunction("main", [], IrType.I32, mainBuilder.blocks));
		var entryBuilder = new IrBuilder(),
			mainResult = entryBuilder.call("main", [], IrType.I32),
			exited = entryBuilder.call("__exit", [mainResult], IrType.Void);
		entryBuilder.returnValue(exited);
		program.functions.push(new IrFunction("__entry", [], IrType.Void, entryBuilder.blocks));
		File.saveBytes(Sys.args()[0], HlWriter.encode(HlLower.lower(program)));
	}
}
