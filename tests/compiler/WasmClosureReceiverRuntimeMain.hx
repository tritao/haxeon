import compiler.ir.Ir;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmModule;
import compiler.backend.wasm.WasmTypes;
import compiler.backend.wasm.WasmTypeIdPlan;
import compiler.backend.wasm.linear.WasmLinearContext;
import compiler.backend.wasm.linear.WasmLinearRuntime;

/** Nominal query signatures retain their checks but share one physical native operation. */
class WasmClosureReceiverRuntimeMain {
	static function main():Void {
		checkSlots();
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (inlining in [false, true])
				checkExecution(target, inlining);
	}

	static function checkSlots():Void {
		var program = new IrProgram("main");
		for (index in 0...32) {
			var name = "Tag" + index;
			program.enums.push({name: name, cases: [{name: "Only", params: []}]});
			program.natives.push({
				name: "query" + index,
				library: "haxeon_runtime",
				symbol: "__closure_receiver_if_match",
				arguments: [Function([EnumTag(name)], EnumTag(name)), Function([I32], I32)],
				result: Dyn
			});
		}
		var module = new WasmModule(),
			functions:Map<String, Int> = [],
			strings:Map<String, Int> = [];
		module.runtimeTypeIds = WasmTypeIdPlan.forProgram(program);
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
		var first = functions.get("query0");
		if (first == null)
			throw "Missing closure receiver probe";
		for (index in 0...32) {
			if (functions.get("query" + index) != first)
				throw "Closure receiver aliases duplicated the physical native body";
			if (!compiler.ir.IrVerifier.sameType(program.natives[index].arguments[0], Function([EnumTag("Tag" + index)], EnumTag("Tag" + index))))
				throw "Sharing a physical native erased its nominal signature";
		}
		Sys.println("PASS: 32 nominal closure queries share one physical native body");
	}

	static function checkExecution(target:String, inlining:Bool):Void {
		var session = new compiler.Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		session.addStandardLibrarySourceRoot("stdlib");
		session.configure("closure-receiver-sharing-" + target + inlining, "closure-receiver-sharing",
			compiler.tools.CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
		session.update("Main.hx",
			'enum Tone { Dark; Light; } enum Heat { Cold; Hot; } '
			+ 'class Source { public function new() {} public function tone(v:Tone):Tone return v; '
			+ 'public function heat(v:Heat):Heat return v; } '
			+ 'function main():Int { var source = new Source(); var tone:Dynamic=source.tone; var heat:Dynamic=source.heat; '
			+ 'var readTone:Tone->Tone=cast tone; var readHeat:Heat->Heat=cast heat; '
			+ 'if(readTone(Light)!=Light || readHeat(Hot)!=Hot) return 1; '
			+ 'try { var wrong:Heat->Heat=cast tone; wrong(Hot); return 2; } catch(error:Dynamic) {} return 42; }');
		var program = session.compile("Main").ir;
		var binary = target == "hl" ? new compiler.backend.hl.HlBackend().compile(program, {target: HashLink, debugNames: true})
			.bytes : new compiler.backend.wasm.WasmBackend().compile(program, {target: target == "wasm32" ? Wasm32 : WasmGc, debugNames: true}).bytes;
		var temp = Sys.getEnv("TMPDIR");
		if (temp == null)
			temp = "out";
		var path = temp
			+ "/closure-receiver-sharing-"
			+ target
			+ inlining
			+ "-"
			+ Std.random(0x7fffffff)
			+ (target == "hl" ? ".hl" : ".wasm");
		sys.io.File.saveBytes(path, binary);
		try {
			var script = 'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;'
				+ 'if(e.main()!==42)throw Error("nominal closure receiver probes");';
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
		Sys.println("PASS: nominal closure receiver probes " + target + " inline=" + inlining);
	}
}
