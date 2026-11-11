import compiler.backend.wasm.WasmBackend;
import compiler.backend.Backend.BackendTarget;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import sys.io.File;
import sys.io.Process;

class WasmDeepStructureMain {
	static function main():Void {
		var builder = new IrBuilder();
		for (_ in 0...1500) {
			var next = builder.createBlock();
			builder.jump(next);
			builder.select(next);
		}
		builder.returnValue(builder.constInt(42));
		var program = new IrProgram("main");
		program.functions = [new IrFunction("main", builder.arguments, I32, builder.blocks, Ordinary)];
		for (target in [Wasm32, WasmGc]) {
			var binary = new WasmBackend().compile(program, {target: target, debugNames: false});
			var path = 'out/wasm-deep-structure-$target.wasm';
			File.saveBytes(path, binary.bytes);
			var process = new Process("node", ["-e", 'const fs=require("fs"); '
				+ 'const instance=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1])),{}); '
				+ 'if(instance.exports.main()!==42) throw Error("wrong result");', path]);
			var error = process.stderr.readAll().toString(), status = process.exitCode();
			process.close();
			if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path);
			if (status != 0) throw 'deep $target function failed: $error';
		}
		Sys.println("PASS: deep structured Wasm functions execute on both targets");
	}
}
