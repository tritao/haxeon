import compiler.Compiler;
import compiler.tools.CompilerDriver;
import compiler.backend.wasm.WasmBackend;
import compiler.hl.HlWriter;

class SourceInlineEnumMain {
	static function assertInline(program:compiler.ir.Ir.IrProgram, expected:Bool) {
		for (declaration in program.enums)
			if (declaration.name == "Packet") {
				if ((declaration.inlineStorage != null) != expected)
					throw "Incorrect program-wide enum classification";
				return;
			}
		throw "Missing Packet declaration";
	}

	static function rejectPointerNull(program:compiler.ir.Ir.IrProgram) {
		var invalid = new compiler.ir.Ir.IrProgram("invalidInlineNull"),
			b = new compiler.ir.IrBuilder();
		b.returnValue(b.constNull(Obj("$inline-enum:Packet")));
		invalid.objects = program.objects;
		invalid.enums = program.enums;
		invalid.interfaces = program.interfaces;
		invalid.staticFields = program.staticFields;
		invalid.natives = program.natives;
		invalid.cNatives = program.cNatives;
		invalid.functions = program.functions.concat([
			new compiler.ir.IrFunction("invalidInlineNull", b.arguments, Obj("$inline-enum:Packet"), b.blocks)
		]);
		var error = "";
		try
			compiler.ir.IrVerifier.verifyFunctions(invalid, ["invalidInlineNull" => true])
		catch (failure:Dynamic)
			error = Std.string(failure);
		if (error.indexOf("inline enum null must use a tag-zero packet") < 0)
			throw "Missing enum packet invariant: " + error;
	}

	static function rejectStaleNativeLayout():Void {
		var program = new compiler.ir.Ir.IrProgram("unused");
		program.enums = [{name: "Value", cases: [{name: "Code", params: [I32]}]}];
		program.objects = [
			{
				name: "NativeHolder",
				isValue: true,
				base: null,
				interfaces: [],
				methods: [],
				nativeLayout: {target: "hashlink", size: 8, alignment: 8},
				fields: [{name: "value", type: Enum("Value")}]
			}
		];
		var planner = new compiler.ir.IrInlineEnumLayout(program.enums, program.objects, 64, HashLink),
			eligibility = new compiler.ir.IrInlineEnumEligibility(program, planner);
		if (eligibility.allowed.exists("Value") || eligibility.reasons.get("Value") != "enclosing native layout")
			throw "Inline selection reused boxed native field offsets";
	}

	static function main() {
		rejectStaleNativeLayout();
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (inlining in [false, true]) {
				var c = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
				c.addStandardLibrarySourceRoot("stdlib");
				c.configure("first-" + target + inlining, "first", CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
				c.update("Main.hx", sys.io.File.getContent("tests/programs/source-inline-enum.hx"));
				var result = c.compile("Main");
				assertInline(result.ir, true);
				rejectPointerNull(result.ir);
				c.update("Main.hx", sys.io.File.getContent("tests/programs/source-inline-enum.hx")
					+ "\nfunction reveal(value:Packet):Dynamic return value;\n");
				assertInline(c.compile("Main").ir, false);
				c.update("Main.hx",
					sys.io.File.getContent("tests/programs/source-inline-enum.hx") +
					'\nfunction reflectUnrelated():Dynamic return Reflect.field({marker:1}, "marker");\n');
				assertInline(c.compile("Main").ir, false);
				c.update("Main.hx", sys.io.File.getContent("tests/programs/source-inline-enum.hx"));
				assertInline(c.compile("Main").ir, true);
				var temp = Sys.getEnv("TMPDIR");
				if (temp == null)
					temp = "out";
				var path = temp + "/first-" + target + inlining + (target == "hl" ? ".hl" : ".wasm");
				var bytes = target == "hl" ? HlWriter.encode(result.module).flatten() : new WasmBackend().compile(result.ir, {
					target: target == "wasm32" ? Wasm32 : WasmGc,
					debugNames: true,
					wasmMemoryStats: target == "wasm32",
					wasmGcStress: target == "wasm32",
					wasmGcAllocationCount: target == "wasm-gc"
				}).bytes;
				sys.io.File.saveBytes(path, bytes);
				var js = 'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;if(e.main()!==42)throw Error("result");e["EnumCensus.prepareRoots"]();global.gc();if(e["EnumCensus.checkRoots"]()!==42)throw Error("enum-only roots lost");const c=e.__allocation_count||e["haxeon.memory.allocation_count"];for(const n of [8,1024]){const before=c();if(e["EnumCensus.perform"](n)!==42*n)throw Error("repeat");if(c()!==before)throw Error("enum transport allocated "+(c()-before));}';
				var status = Sys.command(target == "hl" ? "scripts/hl" : "node", target == "hl" ? [path] : ["--expose-gc", "-e", js, path]);
				if (status != (target == "hl" ? 42 : 0))
					throw "Failed " + target + inlining + " " + status;
				Sys.println("PASS " + target + " inline=" + inlining);
				sys.FileSystem.deleteFile(path);
				checkNativeMapEnum(target, inlining);
			}
	}

	static function checkNativeMapEnum(target:String, inlining:Bool):Void {
		var compiler = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.configure("native-map-enum-" + target + inlining, "map-enum",
			CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
		compiler.update("Main.hx", sys.io.File.getContent("tests/programs/enum-array-iterator-escape.hx"));
		var compiled = compiler.compile("Main"), declaration = Lambda.find(compiled.ir.enums, entry -> entry.name == "IteratorChoice");
		if (declaration == null || declaration.inlineStorage != null)
			throw 'Native reference map did not keep IteratorChoice boxed on $target inline=$inlining';
		var root = Sys.getEnv("TMPDIR");
		if (root == null || root == "") root = "/tmp";
		var path = root + "/native-map-enum-" + target + "-" + inlining + "-" + Std.random(0x7fffffff)
			+ (target == "hl" ? ".hl" : ".wasm");
		if (target == "hl") {
			sys.io.File.saveBytes(path, HlWriter.encode(compiled.module).flatten());
			var vm = Sys.getEnv("HAXEON_HASHLINK_DIR"), process = new sys.io.Process(vm == null ? "scripts/hl" : vm + "/hl", [path]),
				error = process.stderr.readAll().toString(), status = process.exitCode();
			process.close();
			if (status != 42) throw 'Native reference map failed on $target inline=$inlining ($status): $error';
		} else {
			var bytes = new WasmBackend().compile(compiled.ir, {
				target: target == "wasm32" ? Wasm32 : WasmGc,
				debugNames: true,
				wasmMemoryStats: target == "wasm32",
				wasmGcAllocationCount: target == "wasm-gc"
			}).bytes;
			sys.io.File.saveBytes(path, bytes);
			var process = new sys.io.Process("node", ["-e", 'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;if(e.main()!==42)throw Error("result");', path]),
				error = process.stderr.readAll().toString(), status = process.exitCode();
			process.close();
			if (status != 0) throw 'Native reference map failed on $target inline=$inlining ($status): $error';
		}
		sys.FileSystem.deleteFile(path);
		Sys.println('PASS $target inline=$inlining native reference map keeps enum values boxed and iterable');
	}
}
