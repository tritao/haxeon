import compiler.Compiler;
import compiler.tools.CompilerDriver;
import compiler.backend.Backend.BackendTarget;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;

/** Boxed nullary cases are immutable module roots, including when all ordinary owners have been cleared. */
class NullaryEnumCacheMain {
	static function main():Void {
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (inlining in [false, true]) check(target, inlining);
		Sys.println("PASS: boxed nullary cases reuse rooted storage for switches, equality, fields and arrays on all targets");
	}

	static function check(target:String, inlining:Bool):Void {
		var session = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		session.addStandardLibrarySourceRoot("stdlib");
		session.configure("nullary-" + target + inlining, "nullary",
			CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
		session.update("Main.hx", sys.io.File.getContent("tests/fixtures/nullary-enum-cache/Main.hx"));
		var program = session.compile("Main").ir, found = false;
		for (declaration in program.enums)
			if (declaration.name == "CacheFlag") {
				found = true;
				if (declaration.inlineStorage != null) throw "The cache regression must exercise boxed enum storage";
			}
		if (!found) throw "Missing boxed enum declaration";
		var temp = Sys.getEnv("TMPDIR");
		if (temp == null) temp = "out";
		var stem = temp + "/nullary-enum-" + target + "-" + inlining + "-" + Std.random(0x7fffffff),
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
				+ 'if(c()!==before)throw Error("nullary references allocated "+(c()-before)+" objects for "+n+" iterations");}';
			var child = new sys.io.Process(target == "hl" ? "scripts/hl" : "node",
				target == "hl" ? [path] : ["--expose-gc", "-e", js, path]);
			var output = child.stdout.readAll().toString(), error = child.stderr.readAll().toString(), status = child.exitCode();
			child.close();
			if (status != (target == "hl" ? 42 : 0)) throw target + " inline=" + inlining + ": " + status + " " + output + " " + error;
			for (capture in captures) {
				var census:Dynamic = haxe.Json.parse(sys.io.File.getContent(capture));
				if (census.allocations != 0) throw "Nullary references allocated " + census.allocations + " objects";
			}
		} catch (error:Dynamic) {
			cleanup(path, captures);
			throw error;
		}
		cleanup(path, captures);
		Sys.println("PASS: " + target + " inline=" + inlining + ": rooted boxed cases; zero objects for 8/1024 iterations");
	}

	static function cleanup(path:String, captures:Array<String>):Void {
		for (file in [path].concat(captures))
			if (sys.FileSystem.exists(file)) sys.FileSystem.deleteFile(file);
	}
}
