import compiler.Compiler;
import compiler.tools.CompilerDriver;
import compiler.backend.Backend.BackendTarget;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;

/** Closed native enum reads validate at the boundary without nullable raw-value boxing. */
class NativeEnumProjectionMain {
	static final schema = 'interface native_enums @target("portable-abi64") @library("native_enums") { enum Mode : i32 { OFF=0; ON=3; } enum Packed : i32 { MIN=-2147483648; A=-2; B=-1; C=0; D=2; MAX=2147483647; } struct Record @layout(8,4) { mode:Mode @offset(0); modes:array<Mode,1> @offset(4); } }';

	static function rejectImplicit(target:String, inlining:Bool):Void {
		for (body in [
			'var mode:Mode=0;', 'var raw:Int=Mode.Off;',
			'var mode:Mode="off";', 'var raw:String=Mode.Off;'
		]) {
			var compiler = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
			compiler.addStandardLibrarySourceRoot("stdlib");
			compiler.configure("native-enum-negative", "native-enum", CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
			compiler.addFfiInterface("native_enums.hxi", schema);
			compiler.update("Main.hx", 'import native_enums.*; function main():Int { $body return 42; }');
			var rejected = false;
			try compiler.compile("Main") catch (error:Dynamic) {
				if (Std.string(error).indexOf("Type mismatch") < 0) throw error;
				rejected = true;
			}
			if (!rejected) throw "Native enum implicit conversion accepted: " + body;
		}
	}

	static function checkDependencies():Void {
		var compiler = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.addFfiProjection("native_enums.hxmap", '{"interface":"native_enums","package":"nativeprobe","modules":{"functions":"NativeCalls","types":"NativeTypes"}}');
		compiler.addFfiProjection("dependent.hxmap", '{"interface":"dependent","package":"nativeprobe","modules":{"functions":"Dependent","types":"DependentTypes"},"dependencyModules":{"native_enums":"nativeprobe.NativeCalls"},"dependencyTypeModules":{"native_enums":"nativeprobe.NativeTypes"},"typeNames":{"Mode":"nativeprobe.NativeTypes.Mode"}}');
		compiler.addFfiInterface("native_enums.hxi", schema);
		compiler.addFfiInterface("dependent.hxi", 'interface dependent @target("portable-abi64") @library("dependent") @depends("native_enums") { enum Own : i32 { A=0; } extern fn read() -> Mode; }');
		compiler.update("Main.hx", 'import nativeprobe.Dependent; function main():Int return Dependent.read().rawValue();');
		var program = compiler.compile("Main").ir, count = 0;
		for (fn in program.functions)
			if (StringTools.endsWith(fn.name, "NativeTypesEnumDecoders.decodeMode")) count++;
		if (count != 1) throw "Dependent interfaces must share one owning enum decoder, got " + count;
	}

	static function checkNativeCallbacks():Void {
		var compiler = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.configure("native-enum-callback", "native-enum", CompilerDriver.targetDefines("hl"));
		compiler.addFfiInterface("native_enums.hxi", schema.substr(0, schema.length - 1) + ' callback Echo = fn(mode:Mode) -> Mode; }');
		compiler.update("Main.hx", sys.io.File.getContent("tests/fixtures/native-enum-projection/CallbackMain.hx"));
		var program = compiler.compile("Main").ir, entry = new IrBuilder();
		program.natives.push({name:"callbackExit",library:"std",symbol:"sys_exit",arguments:[I32],result:Void});
		if (Lambda.exists(program.functions, fn -> fn.name == "__init")) entry.call("__init", [], Void);
		entry.call("callbackExit", [entry.call("main", [], I32)], Void);
		entry.returnValue(entry.constVoid());
		program.functions.push(new IrFunction("callbackEntry", entry.arguments, Void, entry.blocks, Ordinary));
		program.entryPoint = "callbackEntry";
		var temp = Sys.getEnv("TMPDIR");
		if (temp == null) temp = "out";
		var path = temp + "/native-enum-callback-" + Std.random(0x7fffffff) + ".hl";
		sys.io.File.saveBytes(path, new compiler.backend.hl.HlBackend().compile(program, {target:HashLink,debugNames:true}).bytes);
		try {
			var child = new sys.io.Process("scripts/hl", [path]);
			var output = child.stdout.readAll().toString(), error = child.stderr.readAll().toString(), code = child.exitCode();
			child.close();
			if (code != 42) throw "Native enum callback projection failed: " + code + " " + output + " " + error;
		} catch (error:Dynamic) {
			if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path);
			throw error;
		}
		sys.FileSystem.deleteFile(path);
		Sys.println("PASS: native callback enum arguments/results reject unknown codes on HashLink");
	}

	static function main():Void {
		checkDependencies();
		checkNativeCallbacks();
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (inlining in [false, true]) { rejectImplicit(target, inlining); check(target, inlining); }
		Sys.println("PASS: closed native enum decoders reject unknown values and allocate no objects on all targets");
	}

	static function check(target:String, inlining:Bool):Void {
		var session = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		session.addStandardLibrarySourceRoot("stdlib");
		session.configure("nullary-" + target + inlining, "nullary",
			CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
		session.addFfiInterface("native_enums.hxi", schema);
		session.update("Main.hx", sys.io.File.getContent("tests/fixtures/native-enum-projection/Main.hx"));
		var program = session.compile("Main").ir;
		var temp = Sys.getEnv("TMPDIR");
		if (temp == null) temp = "out";
		var stem = temp + "/native-enum-" + target + "-" + inlining + "-" + Std.random(0x7fffffff),
			path = stem + (target == "hl" ? ".hl" : ".wasm"), captures:Array<String> = [];
		if (target == "hl") {
			program.natives = program.natives.concat([
				{name:"cacheMajor", library:"std", symbol:"gc_major", arguments:[], result:Void},
				{name:"cacheStart", library:"std", symbol:"gc_census_start", arguments:[I32], result:Void},
				{name:"cacheStop", library:"std", symbol:"gc_census_stop", arguments:[], result:Void},
				{name:"cacheReset", library:"std", symbol:"gc_census_reset", arguments:[], result:Void},
				{name:"cacheDump", library:"haxeon_runtime", symbol:"__gc_census_dump", arguments:[Bytes], result:Void},
				{name:"cacheExit", library:"std", symbol:"sys_exit", arguments:[I32], result:Void}
			]);
			var entry = new IrBuilder(), bad = entry.createBlock();
			if (Lambda.exists(program.functions, fn -> fn.name == "__init")) entry.call("__init", [], Void);
			var semantics = entry.call("main", [], I32), ready = entry.createBlock();
			entry.branch(entry.equal(semantics, entry.constInt(42)), ready, bad);
			entry.select(ready);
			entry.call("CaseProbe.prepare", [], Void);
			entry.call("CaseProbe.clearRoots", [], Void);
			entry.call("cacheMajor", [], Void);
			entry.call("CaseProbe.churn", [entry.constInt(256)], Void);
			entry.call("cacheMajor", [], Void);
			entry.call("CaseProbe.prepare", [], Void);
			entry.call("CaseProbe.perform", [entry.constInt(2)], I32);
			for (count in [8, 1024]) {
				var capture = stem + "-" + count + ".json";
				captures.push(capture);
				entry.call("cacheReset", [], Void);
				entry.call("cacheStart", [entry.constInt(0)], Void);
				var result = entry.call("CaseProbe.perform", [entry.constInt(count)], I32);
				entry.call("cacheStop", [], Void);
				entry.call("cacheDump", [entry.constString(capture)], Void);
				var next = entry.createBlock();
				entry.branch(entry.equal(result, entry.constInt(42 * count)), next, bad);
				entry.select(next);
			}
			entry.call("cacheExit", [entry.constInt(42)], Void);
			entry.returnValue(entry.constVoid());
			entry.select(bad);
			entry.call("cacheExit", [entry.constInt(1)], Void);
			entry.returnValue(entry.constVoid());
			program.functions.push(new IrFunction("cacheEntry", entry.arguments, Void, entry.blocks, Ordinary));
			program.entryPoint = "cacheEntry";
		}
		compiler.ir.IrVerifier.verify(program);
		var bytes = target == "hl"
			? new compiler.backend.hl.HlBackend().compile(program, {target:HashLink, debugNames:true}).bytes
			: new compiler.backend.wasm.WasmBackend().compile(program, {
				target:target == "wasm32" ? Wasm32 : WasmGc, debugNames:true,
				wasmMemoryStats:target == "wasm32", wasmGcStress:target == "wasm32", wasmGcAllocationCount:target == "wasm-gc"
			}).bytes;
		sys.io.File.saveBytes(path, bytes);
		try {
			var js = 'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;'
				+ 'if(e.main()!==42)throw Error("case semantics");e["CaseProbe.clearRoots"]();'
				+ 'const collections=e["haxeon.memory.collection_count"],beforeGC=collections?collections():0;'
				+ 'e["CaseProbe.churn"](256);global.gc();if(collections&&collections()<=beforeGC)throw Error("guest did not collect");'
				+ 'e["CaseProbe.prepare"]();if(e["CaseProbe.perform"](2)!==84)throw Error("cached case root lost");'
				+ 'const c=e.__allocation_count||e["haxeon.memory.allocation_count"];'
				+ 'for(const n of [8,1024]){const before=c();if(e["CaseProbe.perform"](n)!==42*n)throw Error("case result");'
				+ 'if(c()!==before)throw Error("native enum reads allocated "+(c()-before)+" objects for "+n+" iterations");}';
			var child = new sys.io.Process(target == "hl" ? "scripts/hl" : "node",
				target == "hl" ? [path] : ["--expose-gc", "-e", js, path]);
			var output = child.stdout.readAll().toString(), error = child.stderr.readAll().toString(), status = child.exitCode();
			child.close();
			if (status != (target == "hl" ? 42 : 0)) throw target + " inline=" + inlining + ": " + status + " " + output + " " + error;
			for (capture in captures) {
				var census:Dynamic = haxe.Json.parse(sys.io.File.getContent(capture));
				if (census.allocations != 0) throw "Native enum reads allocated " + census.allocations + " objects";
			}
		} catch (error:Dynamic) {
			cleanup(path, captures);
			throw error;
		}
		cleanup(path, captures);
		Sys.println("PASS: " + target + " inline=" + inlining + ": checked native enum reads; zero objects for 8/1024 iterations");
	}

	static function cleanup(path:String, captures:Array<String>):Void {
		for (file in [path].concat(captures))
			if (sys.FileSystem.exists(file)) sys.FileSystem.deleteFile(file);
	}
}
