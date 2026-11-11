import compiler.Compiler;
import compiler.Frontend;
import compiler.backend.wasm.WasmBackend;
import compiler.hl.HlWriter;
import compiler.tools.CompilerDriver;

class EnumDynamicOrderMain {
	static function main():Void {
		var semantic = Frontend.compile('@:hlNative("haxeon_runtime", "__reflect_is_enum") extern function kind(value:Dynamic):Bool; '
			+ 'enum Event { Item(value:Int); } class Holder { public function new() {} } '
			+ 'function main():Int { var item:Dynamic = Event.Item(7); return kind(item) && !kind(null) && !kind(new Holder()) && !kind("enum") && !kind(7) ? 42 : 1; }');
		if (new compiler.ir.IrInterpreter(semantic).run("main") != 42)
			throw "Incorrect interpreter enum kind";

		var temp = Sys.getEnv("TMPDIR");
		if (temp == null)
			temp = "out";
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (inlining in [false, true])
				checkTarget(target, inlining, temp);
	}

	static function checkTarget(target:String, inlining:Bool, temp:String):Void {
		var compiler = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.configure("enum-order-" + target + inlining, "enum-order",
			CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
		compiler.update("Main.hx", sys.io.File.getContent("tests/programs/enum-dynamic-equality.hx"));
		var result = compiler.compile("Main"),
			path = temp + "/enum-order-" + target + inlining + (target == "hl" ? ".hl" : ".wasm");
		if (target == "hl")
			sys.io.File.saveBytes(path, HlWriter.encode(result.module).flatten());
		else
			sys.io.File.saveBytes(path, new WasmBackend().compile(result.ir, {
				target: target == "wasm32" ? Wasm32 : WasmGc,
				debugNames: true,
				wasmMemoryStats: target == "wasm32",
				wasmGcAllocationCount: target == "wasm-gc"
			}).bytes);

		var wasmCheck = 'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;'
			+ 'if(e.main()!==42)throw Error("enum comparison");'
			+ 'const c=e.__allocation_count||e["haxeon.memory.allocation_count"];'
			+ 'for(const n of [8,1024]){const before=c();'
			+ 'if(e["CompareCensus.perform"](n)!==42*n)throw Error("comparison result");'
			+ 'if(c()!==before)throw Error("enum kind allocated "+(c()-before));}';
		var status = Sys.command(target == "hl" ? "scripts/hl" : "node",
			target == "hl" ? [path] : ["-e", wasmCheck, path]);
		if (status != (target == "hl" ? 42 : 0))
			throw "Failed " + target + " inline=" + inlining + ": " + status;

		if (target != "hl")
			checkEnumFreeModule(target, path);

		sys.FileSystem.deleteFile(path);
		Sys.println("PASS " + target + " inline=" + inlining);
	}

	static function checkEnumFreeModule(target:String, path:String):Void {
		var program = new compiler.ir.Ir.IrProgram("main"), builder = new compiler.ir.IrBuilder();
		var isEnum = builder.call("enumKind", [builder.constNull(Dyn)], Bool),
			invalid = builder.createBlock(), valid = builder.createBlock();
		builder.branch(isEnum, invalid, valid);
		builder.select(invalid);
		builder.returnValue(builder.constInt(1));
		builder.select(valid);
		builder.returnValue(builder.constInt(42));
		program.functions = [new compiler.ir.IrFunction("main", builder.arguments, I32, builder.blocks, Ordinary)];
		program.natives = [{name: "enumKind", library: "haxeon_runtime", symbol: "__reflect_is_enum", arguments: [Dyn], result: Bool}];
		sys.io.File.saveBytes(path,
			new WasmBackend().compile(program, {target: target == "wasm32" ? Wasm32 : WasmGc, debugNames: true}).bytes);
		var check = 'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;'
			+ 'if(e.main()!==42)throw Error("enum-free module kind query");';
		if (Sys.command("node", ["-e", check, path]) != 0)
			throw "Enum kind query failed in a module without enums";
	}
}
