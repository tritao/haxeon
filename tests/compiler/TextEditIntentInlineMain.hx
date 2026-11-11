import compiler.Compiler;
import compiler.backend.Backend.BackendTarget;
import compiler.backend.wasm.WasmBackend;
import compiler.hl.HlWriter;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.tools.CompilerDriver;

class TextEditIntentInlineMain {
	static function main():Void {
		for (inlining in [false, true]) for (target in ["hl", "wasm32", "wasm-gc"])
			check(target, inlining);
		Sys.println("PASS: reflected nullable TextIntent callback keeps enum payloads inline on all targets");
	}

	static function check(target:String, inlining:Bool):Void {
		var driver = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		driver.addStandardLibrarySourceRoot("stdlib");
		driver.configure("text-intent-" + target + "-" + inlining, "text-intent",
			CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
		driver.update("Main.hx", sys.io.File.getContent("tests/programs/inline-enum-callback-escape.hx"));
		var result = driver.compile("Main"), declaration = Lambda.find(result.ir.enums, entry -> entry.name == "TextIntent");
		if (declaration == null || declaration.inlineStorage == null)
			throw 'TextIntent remained boxed on $target inline=$inlining';

		var root = Sys.getEnv("TMPDIR");
		if (root == null || root == "") root = "/tmp";
		var stem = root + "/text-intent-" + target + "-" + inlining + "-" + Std.random(0x7fffffff),
			module = stem + (target == "hl" ? ".hl" : ".wasm");
		if (target == "hl") {
			var program = result.ir, paths = [for (count in [8, 1024]) stem + "-" + count + ".json"];
			program.natives = program.natives.concat([
				{name:"major", library:"std", symbol:"gc_major", arguments:[], result:Void},
				{name:"start", library:"std", symbol:"gc_census_start", arguments:[I32], result:Void},
				{name:"stop", library:"std", symbol:"gc_census_stop", arguments:[], result:Void},
				{name:"reset", library:"std", symbol:"gc_census_reset", arguments:[], result:Void},
				{name:"dump", library:"haxeon_runtime", symbol:"__gc_census_dump", arguments:[Bytes], result:Void},
				{name:"exit", library:"std", symbol:"sys_exit", arguments:[I32], result:Void}
			]);
			var entry = new IrBuilder(), failure = entry.createBlock();
			entry.call("Census.prepare", [], Void);
			entry.call("major", [], Void);
			for (index in 0...2) {
				var count = index == 0 ? 8 : 1024, next = entry.createBlock();
				entry.call("reset", [], Void);
				entry.call("start", [entry.constInt(0)], Void);
				var value = entry.call("Census.run", [entry.constInt(count)], I32);
				entry.call("stop", [], Void);
				entry.call("dump", [entry.constString(paths[index])], Void);
				entry.branch(entry.equal(value, entry.constInt(count)), next, failure);
				entry.select(next);
			}
			entry.call("exit", [entry.constInt(42)], Void);
			entry.returnValue(entry.constVoid());
			entry.select(failure); entry.call("exit", [entry.constInt(1)], Void); entry.returnValue(entry.constVoid());
			program.functions.push(new IrFunction("entry", entry.arguments, Void, entry.blocks, Ordinary));
			program.entryPoint = "entry";
			sys.io.File.saveBytes(module, new compiler.backend.hl.HlBackend().compile(program, {target:HashLink, debugNames:true}).bytes);
			var vm = Sys.getEnv("HAXEON_HASHLINK_DIR"), process = new sys.io.Process(vm == null ? "scripts/hl" : vm + "/hl", [module]),
				error = process.stderr.readAll().toString(), status = process.exitCode();
			process.close();
			if (status != 42) throw '$target inline=$inlining failed ($status): $error';
			for (path in paths) {
				var census:Dynamic = haxe.Json.parse(sys.io.File.getContent(path));
				if (census.allocations != 0) throw '$target inline=$inlining typed callback allocated: ${haxe.Json.stringify(census)}';
				sys.FileSystem.deleteFile(path);
			}
		} else {
			var backendTarget:BackendTarget = target == "wasm32" ? Wasm32 : WasmGc,
				bytes = new WasmBackend().compile(result.ir, {target:backendTarget, debugNames:true,
					wasmMemoryStats:target == "wasm32", wasmGcAllocationCount:target == "wasm-gc", wasmGcStress:target == "wasm32"}).bytes;
			sys.io.File.saveBytes(module, bytes);
			var js = 'const fs=require("fs"),e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports, '
				+ 'c=e.__allocation_count||e["haxeon.memory.allocation_count"];e["Census.prepare"]();if(global.gc)global.gc();'
				+ 'for(const n of [8,1024]){const b=c(),r=e["Census.run"](n),a=c()-b;if(r!==n||a!==0)throw Error(JSON.stringify({n,r,a}));}'
				+ 'if(e.main()!==42)throw Error("main result");';
			var process = new sys.io.Process("node", ["--expose-gc", "-e", js, module]),
				error = process.stderr.readAll().toString(), status = process.exitCode();
			process.close();
			if (status != 0) throw '$target inline=$inlining failed ($status): $error';
		}
		if (sys.FileSystem.exists(module)) sys.FileSystem.deleteFile(module);
		Sys.println('PASS: $target inline=$inlining TextIntent inline, reflected callback ABI, 0 typed-call allocations at 8/1024');
	}
}
