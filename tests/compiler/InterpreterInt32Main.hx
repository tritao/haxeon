import compiler.Compiler;
import compiler.tools.CompilerDriver;
import compiler.backend.Backend.BackendTarget;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;

class InterpreterInt32Main {
	static function main():Void {
		direct();
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (inlining in [false, true])
				check(target, inlining);
		Sys.println("PASS: interpreter Int32 wrapping and fused string concatenation match all targets");
	}

	static function direct():Void {
		var b = new IrBuilder(),
			low = b.constInt(-2147483648),
			high = b.constInt(2147483647);
		var values = [
			b.sub(low, b.constInt(1)),
			b.add(high, b.constInt(1)),
			b.mul(b.constInt(65536), b.constInt(65536))
		];
		var p = new IrProgram("main");
		for (index in 0...values.length) {
			var fn = new IrFunction("main", b.arguments, I32, b.blocks, Ordinary);
			// Each checked value has its definition in this shared acyclic instruction block.
			b.currentBlock().terminator = null;
			b.returnValue(values[index]);
			p.functions = [fn];
			var expected = index == 0 ? 2147483647 : index == 1 ? -2147483648 : 0;
			if (new compiler.ir.IrInterpreter(p).run("main") != expected)
				throw 'Int32 wrapping case $index';
		}
	}

	static function check(target:String, inlining:Bool):Void {
		var c = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		c.addStandardLibrarySourceRoot("stdlib");
		c.configure("interpreter-scalars-" + target + inlining, "interpreter-scalars",
			CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
		c.update("Main.hx",
			'function sub(value:Int):Int return value-1; function add(value:Int):Int return value+1; function mul(value:Int):Int return value*65536; function concat(a:String,b:String,c:String):String return a+b+c; function main():Int { if(sub(-2147483648)!=2147483647)return 1; if(add(2147483647)!=-2147483648)return 2; if(mul(65536)!=0)return 3; if(concat("one","two","three")!="onetwothree")return 4; return 42; }');
		var p = c.compile("Main").ir;
		if (new compiler.ir.IrInterpreter(p).run("main") != 42)
			throw "Interpreter scalar result";
		var stem = "out/interpreter-int32-" + target + inlining + "-" + Std.random(0x7fffffff),
			path = stem + (target == "hl" ? ".hl" : ".wasm");
		var bytes = target == "hl" ? new compiler.backend.hl.HlBackend().compile(p, {target: HashLink, debugNames: true})
			.bytes : new compiler.backend.wasm.WasmBackend().compile(p, {target: target == "wasm32" ? Wasm32 : WasmGc, debugNames: true}).bytes;
		sys.io.File.saveBytes(path, bytes);
		try {
			var js = 'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;if(e.main()!==42)throw Error("integer/string parity");';
			var child = new sys.io.Process(target == "hl" ? "scripts/hl" : "node", target == "hl" ? [path] : ["-e", js, path]);
			var out = child.stdout.readAll().toString(),
				error = child.stderr.readAll().toString(),
				status = child.exitCode();
			child.close();
			if (status != (target == "hl" ? 42 : 0))
				throw '$target inline=$inlining ($status): $out $error';
		} catch (error:Dynamic) {
			sys.FileSystem.deleteFile(path);
			throw error;
		}
		sys.FileSystem.deleteFile(path);
		Sys.println('PASS: $target inline=$inlining');
	}
}
