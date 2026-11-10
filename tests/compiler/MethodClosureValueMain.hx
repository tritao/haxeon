import compiler.Compiler;
import compiler.tools.CompilerDriver;
import compiler.backend.wasm.WasmBackend;
import compiler.hl.HlWriter;

class MethodClosureValueMain {
	static function checkMismatchedOverride(program:compiler.ir.Ir.IrProgram):Void {
		var key = Std.string(compiler.ir.Ir.IrType.Function([compiler.ir.Ir.IrType.Obj("CallbackRecord")], compiler.ir.Ir.IrType.I32));
		var before = new compiler.backend.wasm.WasmScalarAbi(program, [], true);
		if (!before.scalarClosures.exists(key))
			throw "Typed callback argument was not scalar";
		var altered = new compiler.ir.Ir.IrProgram(program.entryPoint);
		altered.objects = program.objects;
		altered.interfaces = program.interfaces;
		altered.enums = program.enums;
		altered.natives = program.natives;
		altered.cNatives = program.cNatives;
		altered.staticFields = program.staticFields;
		var changed = false;
		altered.functions = [
			for (fn in program.functions) {
				if (fn.name == "OverridingRelay.records") {
					var args = fn.arguments.copy(), arg = args[1];
					args[1] = new compiler.ir.Ir.IrValue(arg.id, arg.name,
						compiler.ir.Ir.IrType.Function([compiler.ir.Ir.IrType.Dyn], compiler.ir.Ir.IrType.I32));
					changed = true;
					fn.derive(fn.blocks, args);
				} else fn;
			}
		];
		if (!changed)
			throw "Missing override fixture";
		if (new compiler.backend.wasm.WasmScalarAbi(altered, [], true).scalarClosures.exists(key))
			throw "An incompatible override admitted a scalar callback";
	}

	static function main() {
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (inlining in [false, true]) {
				var c = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
				c.addStandardLibrarySourceRoot("stdlib");
				c.configure("method-" + target + inlining, "method", CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
				c.update("Main.hx", sys.io.File.getContent("tests/programs/closure-method-value-arguments.hx"));
				var result = c.compile("Main");
				if (target == "wasm32" && !inlining)
					checkMismatchedOverride(result.ir);
				for (e in result.ir.enums)
					if (e.name == "CallbackValue" && e.inlineStorage == null)
						throw "Enum callback unexpectedly boxed";
				var temp = Sys.getEnv("TMPDIR");
				if (temp == null)
					temp = "out";
				var path = temp + "/method-" + target + inlining + (target == "hl" ? ".hl" : ".wasm");
				var bytes = target == "hl" ? HlWriter.encode(result.module).flatten() : new WasmBackend().compile(result.ir, {
					target: target == "wasm32" ? Wasm32 : WasmGc,
					debugNames: true,
					wasmMemoryStats: target == "wasm32",
					wasmGcAllocationCount: target == "wasm-gc"
				}).bytes;
				sys.io.File.saveBytes(path, bytes);
				var js = 'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;if(e.main()!==42)throw Error("result");const c=e.__allocation_count||e["haxeon.memory.allocation_count"];for(const name of ["enums","records","concrete"])for(const n of [8,1024]){const before=c();if(e["CallbackMethodCensus."+name](n)!==84*n)throw Error(name);if(c()!==before)throw Error(name+" allocated "+(c()-before));}';
				var status = Sys.command(target == "hl" ? "scripts/hl" : "node", target == "hl" ? [path] : ["-e", js, path]);
				if (status != (target == "hl" ? 42 : 0))
					throw target + " inline=" + inlining + " failed " + status;
				sys.FileSystem.deleteFile(path);
				Sys.println("PASS " + target + " inline=" + inlining);
			}
	}
}
