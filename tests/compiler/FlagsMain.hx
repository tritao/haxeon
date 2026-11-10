using StringTools;

import compiler.Compiler;
import compiler.tools.CompilerDriver;
import compiler.backend.Backend.BackendTarget;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;

class FlagsMain {
	static function makeCompiler(target:String, inlining:Bool):Compiler {
		var c = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		c.addStandardLibrarySourceRoot("stdlib");
		c.configure("flags-" + target + inlining, "flags", CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
		return c;
	}

	static function rejected(source:String, message:String, ui:Bool = false):Void {
		var c = makeCompiler("hl", true);
		if (ui)
			c.addSourceRoot("packages/ui/haxe");
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
		var declaration = 'enum abstract Access(Int) implements Flags { var Read=1; var Write=2; } ';
		rejected(declaration + 'function main():Int { var value:Access=1; return 42; }', "Type mismatch");
		rejected(declaration + 'function main():Int { var value:Int=Access.Read; return 42; }', "Type mismatch");
		rejected(declaration + 'function main():Int { var value=Access.Read|1; return 42; }', "same flags type");
		rejected('enum abstract Access(Int) from Int implements Flags { var A=1; } function main():Int return 42;', "cannot declare implicit");
		rejected('enum abstract Access(Int) to Int implements Flags { var A=1; } function main():Int return 42;', "cannot declare implicit");
		rejected('enum abstract Access(String) implements Flags { var A="x"; } function main():Int return 42;', "requires an Int");
		rejected('enum abstract Access(Int) implements Flags { var Invalid=3; } function main():Int return 42;', "without a declared single-bit");
		rejected(declaration + 'function accepts<T:Flags>(value:T):Int return 42; function main():Int return accepts(1);', "constraint");
		for (name in [
			  "haxeon.ui.core.UiModifier",             "haxeon.ui.core.UiDirtyFlag",            "haxeon.ui.style.StyleState",
			"haxeon.ui.style.StyleImpact", "haxeon.ui.semantics.AccessibilityState", "haxeon.ui.semantics.AccessibilityAction"
		]) {
			var local = name.substr(name.lastIndexOf(".") + 1),
				header = 'import $name; ';
			rejected(header + 'function main():Int { var value:$local=0; return 42; }', "Type mismatch", true);
			rejected(header + 'function main():Int { var value:Int=$local.empty(); return value; }', "Type mismatch", true);
		}
		var inherited = makeCompiler("hl", true);
		inherited.update("Main.hx",
			'interface LocalFlags extends Flags {} interface LocalRaw extends RawRepresentable {} enum abstract Bits(Int) implements LocalFlags { var A=1; } enum abstract Code(Int) implements LocalRaw { var A=42; } function main():Int { return Bits.A.rawValue() + Code.A.rawValue() - 1; }');
		if (new compiler.ir.IrInterpreter(inherited.compile("Main").ir).run("main") != 42)
			throw "Inherited synthesis conformance was not resolved";
		var defaults = makeCompiler("hl", true);
		defaults.update("DefaultBits.hx", 'enum abstract DefaultBits(Int) implements Flags { var A=1; }');
		defaults.update("Defaults.hx",
			'import DefaultBits; class Defaults { public function new(value:DefaultBits=DefaultBits.empty()) {} public static function raw(value:DefaultBits=DefaultBits.fromRaw(1)):Int return value.rawValue(); }');
		defaults.update("Main.hx", 'function main():Int { new Defaults(); return Defaults.raw()+41; }');
		if (new compiler.ir.IrInterpreter(defaults.compile("Main").ir).run("main") != 42)
			throw "Flags helpers in default arguments lost their module owner";
		defaults.update("Main.hx", 'function main():Int { new Defaults(); return Defaults.raw()+42-1; }');
		if (new compiler.ir.IrInterpreter(defaults.compile("Main").ir).run("main") != 42)
			throw "Retained flags helpers in defaults lost their module owner";
		incremental();
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (inlining in [false, true])
				check(target, inlining);
		Sys.println("PASS: zero-allocation flags/reference-map reads; scalar-map reads match the cast baseline on all targets");
	}

	static function incremental():Void {
		var c = makeCompiler("hl", true);
		c.update("Access.hx", 'enum abstract Access(Int) implements Flags { var A=1; }');
		c.update("Main.hx", 'function main():Int { try { return Access.fromRaw(3).rawValue(); }catch(error:Dynamic){return 0;} }');
		function result():Int
			return new compiler.ir.IrInterpreter(c.compile("Main").ir).run("main");
		if (result() != 0)
			throw "Flags accepted unknown bits";
		c.update("Access.hx", 'enum abstract Access(Int) implements Flags { var A=1; var B=2; }');
		if (result() != 3 || result() != 3)
			throw "Added flag did not update checked constructor";
		c.update("Access.hx", 'enum abstract Access(Int) implements Flags { var A=1; var B=4; }');
		if (result() != 0)
			throw "Changed flag left a stale known-bit mask";
	}

	static function check(target:String, inlining:Bool):Void {
		var c = makeCompiler(target, inlining);
		c.addFfiInterface("native_flags.hxi",
			'interface native_flags @target("portable-abi64") @library("native_flags") { flags Bits8 : u8 { LOW=1; HIGH=128; } flags Bits16 : u16 { LOW=1; HIGH=32768; } flags Bits32 : u32 { LOW=1; HIGH=0x80000000; } flags Bits64 : u64 { LOW=1; HIGH=1<<63; } }');
		var source = sys.io.File.getContent("tests/programs/flags.hx"),
			nativeChecks = 'if (native_flags.__hxi_flags_from_native_Bits8(-1).rawValue()!=129 || native_flags.__hxi_flags_from_native_Bits16(-1).rawValue()!=32769 || native_flags.__hxi_flags_from_native_Bits32(-1).rawValue()!=-2147483647 || haxe.Int64.compare(native_flags.__hxi_flags_from_native_Bits64(haxe.Int64.ofInt(-1)),haxe.Int64.make(-2147483648,1))!=0) return -20;';
		source = source.replace("var value=Access.fromRaw(index&7);", nativeChecks + "var value=Access.fromRaw(index&7);");
		source = "import native_flags.*;\n" + source;
		source = source.replace("function main():Int {",
			'function main():Int { var nativeRejected=false; try { Bits32.fromRaw(2); } catch(error:Dynamic) {nativeRejected=true;} if(!nativeRejected)return -21;');
		c.update("Main.hx", source);
		var result = c.compile("Main"), p = result.ir;
		var interpreted = new compiler.ir.IrInterpreter(p).run("main");
		if (interpreted != 42)
			throw 'Flags interpreter $target inline=$inlining returned $interpreted';
		// Reference-valued maps use native primitives; the interpreter validates the core flags above.
		// Exercise the typed cursor-cache key shape and its read allocations on the three runtimes.
		var mapped = source.replace("class Probe {",
			'enum abstract NativeShape(Int) implements RawRepresentable { var Arrow=0; var Text=1; } class Probe { public static var cache:Map<NativeShape,Holder>; public static var states:Map<Int,Access>;');
		mapped = mapped.replace("total+=read(result);",
			'var cached=cache.get(NativeShape.Text); if(cached==null || cached.code!=Access.Read || !cached.initial.isEmpty())return -3; total+=read(result);');
		mapped = mapped.replace("if(Probe.perform(32)!=32)",
			'Probe.states=new Map(); Probe.states.set(0,Access.empty()); Probe.cache=new Map(); Probe.cache.set(NativeShape.Text,holder); if(Probe.perform(32)!=32)');
		mapped = mapped.replace("public static var states:Map<Int,Access>;",
			'public static var states:Map<Int,Access>; @:expose public static function scalarChecks(count:Int, checked:Bool):Int { var total=0; for(i in 0...count) { if(checked) { if(!states.exists(0))return -4; var state:Access=states.get(0); if(!state.isEmpty())return -4; } else { var state:Access=cast states.get(0); if(!state.isEmpty())return -4; } total++; } return total; }');
		c.update("Main.hx", mapped);
		p = c.compile("Main").ir;
		var holder = Lambda.find(p.objects, o -> o.name == "Holder");
		if (holder == null
			|| holder.fields.length != 2
			|| Lambda.exists(holder.fields, field -> !compiler.ir.IrVerifier.sameType(field.type, I32)))
			throw "A raw Int field must stay I32";
		var pair = Lambda.find(p.objects, o -> o.name == "Pair");
		if (pair == null || pair.nativeLayout == null || pair.nativeLayout.size != 8)
			throw "A raw Int member must keep its four-byte native struct layout";
		var temp = Sys.getEnv("TMPDIR");
		if (temp == null)
			temp = "out";
		var stem = temp + "/flag-values-" + target + inlining + "-" + Std.random(0x7fffffff),
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
			b.call("Probe.perform", [b.constInt(2)], I32);
			for (n in [8, 1024]) {
				b.call("rawReset", [], Void);
				b.call("rawStart", [b.constInt(0)], Void);
				var value = b.call("Probe.perform", [b.constInt(n)], I32);
				b.call("rawStop", [], Void);
				b.call("rawDump", [b.constString(stem + "-" + n + ".json")], Void);
				var next = b.createBlock();
				b.branch(b.equal(value, b.constInt(n)), next, bad);
				b.select(next);
			}
			for (checked in [false, true]) {
				b.call("Probe.scalarChecks", [b.constInt(2), b.constBool(checked)], I32);
				for (n in [8, 1024]) {
					b.call("rawReset", [], Void);
					b.call("rawStart", [b.constInt(0)], Void);
					var value = b.call("Probe.scalarChecks", [b.constInt(n), b.constBool(checked)], I32);
					b.call("rawStop", [], Void);
					b.call("rawDump", [b.constString(stem + "-map-" + checked + "-" + n + ".json")], Void);
					var next = b.createBlock();
					b.branch(b.equal(value, b.constInt(n)), next, bad);
					b.select(next);
				}
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
				'e["Probe.perform"](2);for(const n of [8,1024]){const before=count();if(e["Probe.perform"](n)!==n)throw Error("raw loop");if(count()!==before)throw Error("raw values boxed");}'
				+
				'for(const n of [8,1024]){const measures=[],bytes=e["haxeon.memory.allocated_bytes"];for(const checked of [false,true]){e["Probe.scalarChecks"](2,checked);const before=count(),beforeBytes=bytes?bytes():0;if(e["Probe.scalarChecks"](n,checked)!==n)throw Error("scalar map semantics");measures.push({objects:count()-before,bytes:bytes?bytes()-beforeBytes:null});}console.log("scalar map",n,JSON.stringify(measures));if(measures[1].objects>measures[0].objects||measures[1].bytes>measures[0].bytes)throw Error("checked map read allocated more");}';
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
			if (target == "hl")
				for (n in [8, 1024]) {
					var baseline:Dynamic = haxe.Json.parse(sys.io.File.getContent(stem + "-map-false-" + n + ".json"));
					var checked:Dynamic = haxe.Json.parse(sys.io.File.getContent(stem + "-map-true-" + n + ".json"));
					function allocated(census:Dynamic):Float {
						var total:Float = 0,
							types:Array<Dynamic> = census.types;
						for (type in types)
							total += type.bytes;
						return total;
					}
					if (checked.allocations > baseline.allocations || allocated(checked) > allocated(baseline))
						throw "Checked scalar-map read allocated more than its cast baseline";
					Sys.println('scalar map hl $n: ${baseline.allocations}/${allocated(baseline)} -> ${checked.allocations}/${allocated(checked)} objects/bytes');
				}
			else
				Sys.print(output);
		} catch (error:Dynamic) {
			cleanup(stem);
			throw error;
		}
		cleanup(stem);
		Sys.println('PASS: $target inline=$inlining flag contracts and primitive storage');
	}

	static function cleanup(stem:String):Void {
		var dir = haxe.io.Path.directory(stem),
			name = haxe.io.Path.withoutDirectory(stem);
		for (file in sys.FileSystem.readDirectory(dir))
			if (StringTools.startsWith(file, name))
				sys.FileSystem.deleteFile(dir + "/" + file);
	}
}
