import compiler.ir.Ir;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmModule;
import compiler.backend.wasm.WasmTypes;
import compiler.backend.wasm.WasmTypeIdPlan;
import compiler.backend.wasm.linear.WasmLinearContext;
import compiler.backend.wasm.linear.WasmLinearRuntime;

/** Finalization fills existing slots: appending an orphan duplicated the whole stringifier. */
class WasmStringFinalizationMain {
	static function main():Void {
		checkSlots();
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (inlining in [false, true])
				checkExecution(target, inlining);
	}

	static function checkSlots():Void {
		var program = new IrProgram("main");
		program.natives = [
			{
				name: "__std_string",
				library: "haxeon_runtime",
				symbol: "__std_string",
				arguments: [Dyn],
				result: Bytes
			}
		];
		var module = new WasmModule(), functions:Map<String, Int> = [], strings:Map<String, Int> = [], index = 8;
		module.runtimeTypeIds = WasmTypeIdPlan.forProgram(program);
		for (text in ["null", "Object", "true", "false"]) {
			strings.set(text, index);
			index += 8;
		}
		var allocator = module.addFunction(new WasmFunction("allocator", {parameters: [I32], results: [I32]}, [], [I32Const(0), Return])),
			context = new WasmLinearContext(module, program, new WasmLayout(program), {target: Wasm32, debugNames: true}, {
				functions: functions,
				globals: [],
				rootGlobals: [],
				strings: strings,
				heapStart: 0,
				rootBase: 0,
				rootTop: 0,
				rootFrameTop: 0,
				rootLimit: 0,
				markStackTop: 0,
				heapState: 0,
				reflectionTable: 0,
				reflectionCount: 0,
				reflectionBytes: null
			});
		context.allocatorFunction = allocator;
		WasmLinearRuntime.register(context);
		var slot = functions.get("__std_string"),
			count = module.functions.length;
		if (slot == null)
			throw "Missing stringifier";
		for (_ in 0...2) {
			WasmLinearRuntime.finalizeDynamicString(context);
			if (module.functions.length != count || functions.get("__std_string") != slot)
				throw "String finalization appended a duplicate function or moved its slot";
		}
		for (name in ["__std_string", "__haxeon_i32_to_string", "__haxeon_i64_to_string"]) {
			var found = 0;
			for (fn in module.functions)
				if (fn.name == name)
					found++;
			if (found != 1)
				throw 'Expected one "$name", found $found';
		}
		Sys.println("PASS: dynamic string finalization preserves slots and emits one stringifier and one formatter per numeric kind");
	}

	static function checkExecution(target:String, inlining:Bool):Void {
		var session = new compiler.Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		session.addStandardLibrarySourceRoot("stdlib");
		session.configure("string-finalization-" + target + inlining, "string-finalization",
			compiler.tools.CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
		session.update("Main.hx",
			'enum Tone { Dark; Light; } '
			+ 'class Label { public function new() {} public function toString():String return "label"; } '
			+ 'function main():Int { var number:Dynamic=17, tone:Dynamic=Light, label:Dynamic=new Label(); '
			+ 'return Std.string(number)=="17" && Std.string(tone)=="Light" && Std.string(label)=="label" '
			+ '&& Std.string(true)=="true" && Std.string(null)=="null" ? 42 : 1; }');
		var program = session.compile("Main").ir;
		var binary = target == "hl" ? new compiler.backend.hl.HlBackend().compile(program, {target: HashLink, debugNames: true})
			.bytes : new compiler.backend.wasm.WasmBackend().compile(program, {target: target == "wasm32" ? Wasm32 : WasmGc, debugNames: true}).bytes;
		var temp = Sys.getEnv("TMPDIR");
		if (temp == null)
			temp = "out";
		var path = temp + "/string-finalization-" + target + inlining + "-" + Std.random(0x7fffffff) + (target == "hl" ? ".hl" : ".wasm");
		sys.io.File.saveBytes(path, binary);
		try {
			var script = 'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;'
				+ 'if(e.main()!==42)throw Error("dynamic stringification");';
			var child = new sys.io.Process(target == "hl" ? "scripts/hl" : "node", target == "hl" ? [path] : ["-e", script, path]);
			var output = child.stdout.readAll().toString(),
				error = child.stderr.readAll().toString(),
				status = child.exitCode();
			child.close();
			if (status != (target == "hl" ? 42 : 0))
				throw target + " inline=" + inlining + ": " + output + error;
		} catch (error:Dynamic) {
			sys.FileSystem.deleteFile(path);
			throw error;
		}
		sys.FileSystem.deleteFile(path);
		Sys.println("PASS: dynamic stringification " + target + " inline=" + inlining);
	}
}
