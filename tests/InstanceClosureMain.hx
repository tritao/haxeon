import compiler.hl.HlWriter;
import compiler.ir.HlLower;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import sys.io.File;

class InstanceClosureMain {
	static function main():Void {
		var methodBuilder = new IrBuilder(),
			self = methodBuilder.argument("this", IrType.Obj("Env")),
			argument = methodBuilder.argument("value", IrType.I32),
			captured = methodBuilder.fieldGet(self, "value", IrType.I32),
			result = methodBuilder.add(captured, argument);
		methodBuilder.returnValue(result);

		var mainBuilder = new IrBuilder(),
			env = mainBuilder.newObject("Env"),
			captured = mainBuilder.constInt(21);
		mainBuilder.fieldSet(env, "value", captured);
		var closure = mainBuilder.instanceClosure("Env.invoke", env, IrType.Function([IrType.I32], IrType.I32)),
			input = mainBuilder.constInt(21),
			answer = mainBuilder.callClosure(closure, [input], IrType.I32);
		mainBuilder.returnValue(answer);

		var program = new IrProgram("__entry");
		program.natives.push({
			name: "__exit",
			library: "std",
			symbol: "sys_exit",
			arguments: [IrType.I32],
			result: IrType.Void
		});
		program.objects.push({name: "Env", base: null, fields: [{name: "value", type: IrType.I32}]});
		program.functions.push(new IrFunction("Env.invoke", methodBuilder.arguments, IrType.I32, methodBuilder.blocks));
		program.functions.push(new IrFunction("main", [], IrType.I32, mainBuilder.blocks));
		var entryBuilder = new IrBuilder(),
			mainResult = entryBuilder.call("main", [], IrType.I32),
			exited = entryBuilder.call("__exit", [mainResult], IrType.Void);
		entryBuilder.returnValue(exited);
		program.functions.push(new IrFunction("__entry", [], IrType.Void, entryBuilder.blocks));
		File.saveBytes(Sys.args()[0], HlWriter.encode(HlLower.lower(program)));
	}
}
