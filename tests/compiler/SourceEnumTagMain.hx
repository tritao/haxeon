import compiler.Compiler;
import compiler.tools.CompilerDriver;
import compiler.backend.Backend.BackendTarget;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;

/** Payload-free source enums use nominal scalar storage even in fields, reflection and arrays. */
class SourceEnumTagMain {
	static function main():Void {
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (inlining in [false, true])
				check(target, inlining);
		Sys.println("PASS: source tags preserve nominal identity for switches, equality, fields and arrays on all targets");
	}

	static function check(target:String, inlining:Bool):Void {
		var session = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		session.addStandardLibrarySourceRoot("stdlib");
		session.configure("source-tag-" + target + inlining, "source-tag",
			CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
		session.update("Main.hx", sys.io.File.getContent("tests/programs/enum-tag-storage.hx"));
		var program = session.compile("Main").ir, found = false;
		for (declaration in program.enums)
			if (declaration.name == "Mode") {
				found = true;
				if (declaration.inlineStorage != null)
					throw "Tag enums must not use a payload packet";
			}
		if (!found)
			throw "Missing tag enum declaration";
		var holder = Lambda.find(program.objects, object -> object.name == "Holder");
		if (holder == null
			|| holder.fields.length != 2
			|| Lambda.exists(holder.fields, field -> !compiler.ir.IrVerifier.sameType(field.type, EnumTag("Mode"))))
			throw "Reflected class fields must use four-byte tags, including nullable enum fields";
		var pair = Lambda.find(program.objects, object -> object.name == "TaggedPair");
		if (pair == null || pair.nativeLayout == null || pair.nativeLayout.size != 8 || pair.fields[0].nativeLayout.size != 4)
			throw "Flat enum fields lost their native scalar size";
		var temp = Sys.getEnv("TMPDIR");
		if (temp == null)
			temp = "out";
		var stem = temp + "/source-enum-tag-" + target + "-" + inlining + "-" + Std.random(0x7fffffff),
			path = stem + (target == "hl" ? ".hl" : ".wasm"),
			captures:Array<String> = [];
		if (target == "hl") {
			program.natives = program.natives.concat([
				{
					name: "cacheMajor",
					library: "std",
					symbol: "gc_major",
					arguments: [],
					result: Void
				},
				{
					name: "cacheStart",
					library: "std",
					symbol: "gc_census_start",
					arguments: [I32],
					result: Void
				},
				{
					name: "cacheStop",
					library: "std",
					symbol: "gc_census_stop",
					arguments: [],
					result: Void
				},
				{
					name: "cacheReset",
					library: "std",
					symbol: "gc_census_reset",
					arguments: [],
					result: Void
				},
				{
					name: "cacheDump",
					library: "haxeon_runtime",
					symbol: "__gc_census_dump",
					arguments: [Bytes],
					result: Void
				},
				{
					name: "cacheExit",
					library: "std",
					symbol: "sys_exit",
					arguments: [I32],
					result: Void
				}
			]);
			var entry = new IrBuilder(), bad = entry.createBlock();
			if (Lambda.exists(program.functions, fn -> fn.name == "__init"))
				entry.call("__init", [], Void);
			var checkedMain = entry.call("main", [], I32),
				goodMain = entry.createBlock();
			entry.branch(entry.equal(checkedMain, entry.constInt(42)), goodMain, bad);
			entry.select(goodMain);
			entry.call("Probe.prepare", [], Void);

			entry.call("Probe.perform", [entry.constInt(2)], I32);
			for (count in [8, 1024]) {
				var capture = stem + "-" + count + ".json";
				captures.push(capture);
				entry.call("cacheReset", [], Void);
				entry.call("cacheStart", [entry.constInt(0)], Void);
				var result = entry.call("Probe.perform", [entry.constInt(count)], I32);
				entry.call("cacheStop", [], Void);
				entry.call("cacheDump", [entry.constString(capture)], Void);
				var next = entry.createBlock();
				entry.branch(entry.equal(result, entry.constInt(42 * count)), next, bad);
				entry.select(next);
			}
			entry.call("Probe.allocateArray", [entry.constInt(1024)], I32);
			for (count in [8, 1024]) {
				var capture = stem + "-array-" + count + ".json";
				captures.push(capture);
				entry.call("cacheReset", [], Void);
				entry.call("cacheStart", [entry.constInt(0)], Void);
				entry.call("Probe.allocateArray", [entry.constInt(count)], I32);
				entry.call("cacheStop", [], Void);
				entry.call("cacheDump", [entry.constString(capture)], Void);
			}
			entry.call("cacheExit", [entry.constInt(42)], Void);
			entry.returnValue(entry.constVoid());
			entry.select(bad);
			entry.call("cacheExit", [entry.constInt(1)], Void);
			entry.returnValue(entry.constVoid());
			program.functions.push(new IrFunction("cacheEntry", entry.arguments, Void, entry.blocks));
			program.entryPoint = "cacheEntry";
		}
		compiler.ir.IrVerifier.verify(program);
		var bytes = target == "hl" ? new compiler.backend.hl.HlBackend().compile(program, {target: HashLink, debugNames: true})
			.bytes : new compiler.backend.wasm.WasmBackend().compile(program, {
				target: target == "wasm32" ? Wasm32 : WasmGc,
				debugNames: true,
				wasmMemoryStats: target == "wasm32",
				wasmGcStress: target == "wasm32",
				wasmGcAllocationCount: target == "wasm-gc"
			}).bytes;
		sys.io.File.saveBytes(path, bytes);
		try {
			var js = 'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;'
				+ 'if(e.main()!==42)throw Error("tag semantics "+e.main());'
				+ 'e["Probe.prepare"]();if(e["Probe.perform"](2)!==84)throw Error("cached case root lost");'
				+ 'const c=e.__allocation_count||e["haxeon.memory.allocation_count"];'
				+ 'for(const n of [8,1024]){const before=c();if(e["Probe.perform"](n)!==42*n)throw Error("case result");'
				+ 'if(c()!==before)throw Error("nullary references allocated "+(c()-before)+" objects for "+n+" iterations");}'
				+
				'e["Probe.allocateArray"](1024);const counts=[];for(const n of [8,1024]){const before=c();if(e["Probe.allocateArray"](n)!==n)throw Error("array length");counts.push(c()-before);}if(counts[0]!==counts[1])throw Error("per-element array allocations: "+counts);';
			var child = new sys.io.Process(target == "hl" ? "scripts/hl" : "node", target == "hl" ? [path] : ["--expose-gc", "-e", js, path]);
			var output = child.stdout.readAll().toString(),
				error = child.stderr.readAll().toString(),
				status = child.exitCode();
			child.close();
			if (status != (target == "hl" ? 42 : 0))
				throw target + " inline=" + inlining + ": " + status + " " + output + " " + error;
			var arrayCensuses:Array<Dynamic> = [];
			for (capture in captures) {
				var census:Dynamic = haxe.Json.parse(sys.io.File.getContent(capture));
				if (capture.indexOf("-array-") >= 0) {
					arrayCensuses.push(census);
					continue;
				}
				if (census.allocations != 0)
					throw "Nullary references allocated " + census.allocations + " objects";
			}
			if (target == "hl") {
				var bytes:Array<Float> = [];
				for (census in arrayCensuses) {
					var total = 0.0;
					for (entry in (cast census.types : Array<Dynamic>))
						total += entry.bytes;
					bytes.push(total);
				}
				if (arrayCensuses.length != 2 || arrayCensuses[0].allocations != arrayCensuses[1].allocations || bytes[1] <= bytes[0])
					throw "Tag array construction must have constant object count: " + haxe.Json.stringify(bytes);
				Sys.println('HashLink tag arrays: 8/1024 elements, objects=${arrayCensuses[0].allocations}/${arrayCensuses[1].allocations}, bytes='
					+ bytes.join("/"));
			}
		} catch (error:Dynamic) {
			cleanup(path, captures);
			throw error;
		}
		cleanup(path, captures);
		Sys.println("PASS: " + target + " inline=" + inlining + ": source tags and checked reflection; zero objects for 8/1024 iterations");
	}

	static function cleanup(path:String, captures:Array<String>):Void {
		for (file in [path].concat(captures))
			if (sys.FileSystem.exists(file))
				sys.FileSystem.deleteFile(file);
	}
}
