import compiler.Compiler;
import compiler.tools.CompilerDriver;
import compiler.backend.Backend.BackendTarget;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;

class RawRepresentableMain {
	static function makeCompiler(target:String, inlining:Bool):Compiler {
		var c = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		c.addStandardLibrarySourceRoot("stdlib");
		c.configure("raw-" + target + inlining, "raw", CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
		return c;
	}

	static function rejected(source:String, message:String):Void {
		var c = makeCompiler("hl", true);
		c.update("Main.hx", source);
		var error = "";
		try
			c.compile("Main")
		catch (failure:Dynamic)
			error = Std.string(failure);
		if (error.indexOf(message) < 0)
			throw 'Expected "$message", got "$error"';
	}

	static function main():Void {
		var decl = 'enum abstract Code(Int) implements RawRepresentable { var A=4; } ';
		rejected(decl + 'function main():Int { var bad:Code=4; return 42; }', "Type mismatch");
		rejected(decl + 'function main():Int { var bad:Int=Code.A; return 42; }', "Type mismatch");
		rejected('enum abstract Mime(String) implements RawRepresentable { var Text="text"; } function main():Int { var bad:Mime="text"; return 42; }',
			"Type mismatch");
		rejected('enum abstract Mime(String) implements RawRepresentable { var Text="text"; } function main():Int { var bad:String=Mime.Text; return 42; }',
			"Type mismatch");
		rejected('enum abstract Code(Int) from Int implements RawRepresentable { var A=4; } function main():Int return 42;', "cannot declare implicit");
		rejected('enum abstract Code(Int) to Int implements RawRepresentable { var A=4; } function main():Int return 42;', "cannot declare implicit");
		rejected('enum abstract Bad(Float) implements RawRepresentable { var A=1.0; } function main():Int return 42;', "requires an Int or String");
		rejected(decl + 'function main():Int { Code.fromRaw("wrong"); return 42; }', "Type mismatch");
		rejected(decl + 'function accepts<T:RawRepresentable>(value:T):Int return 42; function main():Int return accepts(4);', "constraint");
		rejected(decl + 'enum abstract Other(Int) implements RawRepresentable { var A=4; } function main():Int { var bad:Other=Code.A; return 42; }',
			"Type mismatch");

		incremental();
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (inlining in [false, true])
				check(target, inlining);
		Sys.println("PASS: synthesized raw values, closed conversions and current constants on all targets");
	}

	static function incremental():Void {
		var c = makeCompiler("hl", true);
		c.update("Code.hx", 'enum abstract Code(Int) implements RawRepresentable { var A=4; }');
		c.update("Main.hx", 'function main():Int { var value=Code.fromRaw(7); return value==null ? 0 : value.rawValue(); }');
		function result():Int
			return new compiler.ir.IrInterpreter(c.compile("Main").ir).run("main");
		if (result() != 0)
			throw "Unknown initial raw value";
		c.update("Code.hx", 'enum abstract Code(Int) implements RawRepresentable { var A=4; var B=7; }');
		if (result() != 7 || result() != 7)
			throw "Added constant did not update retained raw helper";
		c.update("Code.hx", 'enum abstract Code(Int) implements RawRepresentable { var A=4; var B=8; }');
		if (result() != 0)
			throw "Changed constant left a stale raw helper";
		c.update("Code.hx", 'enum abstract Code(Int) implements RawRepresentable { var A=7; }');
		if (result() != 7)
			throw "Replaced constant did not update raw helper";
		var imported = makeCompiler("hl", true);
		imported.update("wire/Code.hx", 'package wire; enum abstract Code(Int) implements RawRepresentable { var A=4; }');
		imported.update("Main.hx",
			'import wire.Code as WireCode; function main():Int { var value=WireCode.fromRaw(4); return value==null ? 0 : value.rawValue(); }');
		if (new compiler.ir.IrInterpreter(imported.compile("Main").ir).run("main") != 4)
			throw "Imported raw conformance";

		Sys.println("PASS: incremental raw conversion uses current constants");
	}

	static function check(target:String, inlining:Bool):Void {
		var c = makeCompiler(target, inlining);
		c.update("Main.hx", sys.io.File.getContent("tests/programs/raw-representable.hx"));
		var result = c.compile("Main"), p = result.ir;
		if (new compiler.ir.IrInterpreter(p).run("main") != 42)
			throw "Raw interpreter result";
		var holder = Lambda.find(p.objects, o -> o.name == "Holder");
		if (holder == null || holder.fields.length != 1 || !compiler.ir.IrVerifier.sameType(holder.fields[0].type, I32))
			throw "A raw Int field must stay I32";
		var pair = Lambda.find(p.objects, o -> o.name == "Pair");
		if (pair == null || pair.nativeLayout == null || pair.nativeLayout.size != 8)
			throw "A raw Int member must keep its four-byte native struct layout";
		var temp = Sys.getEnv("TMPDIR");
		if (temp == null)
			temp = "out";
		var stem = temp + "/raw-values-" + target + inlining + "-" + Std.random(0x7fffffff),
			path = stem + (target == "hl" ? ".hl" : ".wasm");
		if (target == "hl") {
			p.natives = p.natives.concat([
				{
					name: "rawReset",
					library: "std",
					symbol: "gc_census_reset",
					arguments: [],
					result: Void
				},
				{
					name: "rawStart",
					library: "std",
					symbol: "gc_census_start",
					arguments: [I32],
					result: Void
				},
				{
					name: "rawStop",
					library: "std",
					symbol: "gc_census_stop",
					arguments: [],
					result: Void
				},
				{
					name: "rawDump",
					library: "haxeon_runtime",
					symbol: "__gc_census_dump",
					arguments: [Bytes],
					result: Void
				},
				{
					name: "rawExit",
					library: "std",
					symbol: "sys_exit",
					arguments: [I32],
					result: Void
				}
			]);
			var b = new IrBuilder(), bad = b.createBlock();
			if (Lambda.exists(p.functions, f -> f.name == "__init"))
				b.call("__init", [], Void);
			var good = b.createBlock();
			b.branch(b.equal(b.call("main", [], I32), b.constInt(42)), good, bad);
			b.select(good);
			b.call("Probe.raw", [b.constInt(2)], I32);
			for (n in [8, 1024]) {
				b.call("rawReset", [], Void);
				b.call("rawStart", [b.constInt(0)], Void);
				var value = b.call("Probe.raw", [b.constInt(n)], I32);
				b.call("rawStop", [], Void);
				b.call("rawDump", [b.constString(stem + "-" + n + ".json")], Void);
				var next = b.createBlock();
				b.branch(b.equal(value, b.constInt(11 * n)), next, bad);
				b.select(next);
			}
			b.call("rawExit", [b.constInt(42)], Void);
			b.returnValue(b.constVoid());
			b.select(bad);
			b.call("rawExit", [b.constInt(1)], Void);
			b.returnValue(b.constVoid());
			p.functions.push(new IrFunction("rawEntry", b.arguments, Void, b.blocks));
			p.entryPoint = "rawEntry";
		}
		var bytes = target == "hl" ? new compiler.backend.hl.HlBackend().compile(p, {target: HashLink, debugNames: true})
			.bytes : new compiler.backend.wasm.WasmBackend().compile(p, {
				target: target == "wasm32" ? Wasm32 : WasmGc,
				debugNames: true,
				wasmGcAllocationCount: target == "wasm-gc",
				wasmMemoryStats: target == "wasm32"
			}).bytes;
		sys.io.File.saveBytes(path, bytes);
		try {
			var js = 'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;'
				+ 'if(e.main()!==42)throw Error("raw semantics"); const count=e.__allocation_count||e["haxeon.memory.allocation_count"];'
				+
				'e["Probe.raw"](2);for(const n of [8,1024]){const before=count();if(e["Probe.raw"](n)!==11*n)throw Error("raw loop");if(count()!==before)throw Error("raw values boxed");}';
			var child = new sys.io.Process(target == "hl" ? "scripts/hl" : "node", target == "hl" ? [path] : ["--expose-gc", "-e", js, path]);
			var output = child.stdout.readAll().toString() + child.stderr.readAll().toString(),
				code = child.exitCode();
			child.close();
			if (code != (target == "hl" ? 42 : 0))
				throw 'Raw $target inline=$inlining failed ($code): $output';
			if (target == "hl")
				for (n in [8, 1024]) {
					var census:Dynamic = haxe.Json.parse(sys.io.File.getContent(stem + "-" + n + ".json"));
					if (census.allocations != 0)
						throw "Raw values allocated " + census.allocations + " objects";
				}
		} catch (error:Dynamic) {
			cleanup(stem);
			throw error;
		}
		cleanup(stem);
		Sys.println('PASS: $target inline=$inlining raw contracts and primitive storage');
	}

	static function cleanup(stem:String):Void {
		var dir = haxe.io.Path.directory(stem),
			name = haxe.io.Path.withoutDirectory(stem);
		for (file in sys.FileSystem.readDirectory(dir))
			if (StringTools.startsWith(file, name))
				sys.FileSystem.deleteFile(dir + "/" + file);
	}
}
