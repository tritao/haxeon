import compiler.hl.HlWriter;
import compiler.ir.HlLower;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import sys.io.File;

class ObjectMain {
	static function main():Void {
		var builder = new IrBuilder(),
			object = builder.newObject("Box"),
			value = builder.constInt(42);
		builder.fieldSet(object, "value", value);
		var result = builder.fieldGet(object, "value", IrType.I32);
		builder.returnValue(result);
		var program = new IrProgram("main");
		program.natives.push({
			name: "__exit",
			library: "std",
			symbol: "sys_exit",
			arguments: [IrType.I32],
			result: IrType.Void
		});
		program.objects.push({name: "Box", base: null, fields: [{name: "value", type: IrType.I32}]});
		program.functions.push(new IrFunction("main", [], IrType.I32, builder.blocks));
		var entry = new IrBuilder(),
			mainResult = entry.call("main", [], IrType.I32),
			exited = entry.call("__exit", [mainResult], IrType.Void);
		entry.returnValue(exited);
		program.functions.push(new IrFunction("__entry", [], IrType.Void, entry.blocks));
		program.entryPoint = "__entry";
		var lowered = HlLower.lower(program);
		var output = Sys.args()[0];
		File.saveBytes(output, HlWriter.encode(lowered));
	}
}
