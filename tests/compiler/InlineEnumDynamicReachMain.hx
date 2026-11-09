import compiler.Compiler;
import compiler.backend.Backend.BackendTarget;
import compiler.backend.wasm.WasmBackend;
import compiler.backend.hl.HlBackend;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.tools.CompilerDriver;

class InlineEnumDynamicReachMain {
	static final enums = ["DirectIntent", "ArrayIntent", "MapIntent", "ClosureIntent"];

	static function main():Void {
		for (inlining in [false, true]) for (target in ["hl", "wasm32", "wasm-gc"])
			check(target, inlining);
		Sys.println("PASS: Dynamic class escape follows class, array, map, and closure fields to nested enums");
	}

	static function check(target:String, inlining:Bool):Void {
		var driver = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		driver.addStandardLibrarySourceRoot("stdlib");
		driver.configure("inline-dynamic-reach-" + target + "-" + inlining, "inline-dynamic-reach",
			CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
		driver.update("Main.hx", sys.io.File.getContent("tests/programs/inline-enum-dynamic-reach.hx"));
		var program = driver.compile("Main").ir;
		var laneTarget:compiler.ir.IrValueLaneLayout.IrValueLaneTarget = switch target {
			case "hl": HashLink;
			case "wasm32": Wasm32;
			default: WasmGc;
			}, eligibility = new compiler.ir.IrInlineEnumEligibility(program,
			new compiler.ir.IrInlineEnumLayout(program.enums, program.objects, target == "wasm-gc" ? 64 : 32, laneTarget));
		for (name in enums) {
			var declaration = Lambda.find(program.enums, entry -> entry.name == name);
			if (declaration == null || declaration.inlineStorage != null)
				throw '$name was not kept boxed after transitive Dynamic escape on $target inline=$inlining';
			if (eligibility.reasons.get(name) != "Dynamic escape")
				throw '$name was not rejected by the transitive Dynamic escape graph on $target inline=$inlining: ${eligibility.reasons.get(name)}';
		}

		var root = Sys.getEnv("TMPDIR");
		if (root == null || root == "") root = "/tmp";
		var stem = root + "/inline-dynamic-reach-" + target + "-" + inlining + "-" + Std.random(0x7fffffff),
			module = stem + (target == "hl" ? ".hl" : ".wasm");
		if (target == "hl") {
			program.natives.push({name: "exit", library: "std", symbol: "sys_exit", arguments: [I32], result: Void});
			var entry = new IrBuilder();
			entry.call("exit", [entry.call("main", [], I32)], Void);
			entry.returnValue(entry.constVoid());
			program.functions.push(new IrFunction("entry", entry.arguments, Void, entry.blocks));
			program.entryPoint = "entry";
			sys.io.File.saveBytes(module, new HlBackend().compile(program, {target: HashLink, debugNames: true}).bytes);
			var vm = Sys.getEnv("HAXEON_HASHLINK_DIR"), process = new sys.io.Process(vm == null ? "scripts/hl" : vm + "/hl", [module]),
				error = process.stderr.readAll().toString(), status = process.exitCode();
			process.close();
			if (status != 42) throw '$target inline=$inlining dynamic-reach module failed ($status): $error';
		} else {
			var backendTarget:BackendTarget = target == "wasm32" ? Wasm32 : WasmGc,
				bytes = new WasmBackend().compile(program, {target: backendTarget, debugNames: true,
					wasmMemoryStats: target == "wasm32", wasmGcAllocationCount: target == "wasm-gc"}).bytes;
			sys.io.File.saveBytes(module, bytes);
			var js = 'const fs=require("fs"),e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;'
				+ 'if(e.main()!==42)throw Error("dynamic reach result");';
			var process = new sys.io.Process("node", ["-e", js, module]), error = process.stderr.readAll().toString(), status = process.exitCode();
			process.close();
			if (status != 0) throw '$target inline=$inlining dynamic-reach module failed ($status): $error';
		}
		if (sys.FileSystem.exists(module)) sys.FileSystem.deleteFile(module);
		Sys.println('PASS: $target inline=$inlining transitive Dynamic escape retains boxed enum fields');
	}
}
