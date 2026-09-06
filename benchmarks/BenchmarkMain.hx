package;

import compiler.hl.HlWriter;
import compiler.modules.Compiler;
import compiler.modules.Compiler.CompileMetrics;
import haxe.Json;
import haxe.io.Bytes;
import runtime.LoadedModule;
import runtime.PatchSet;
import runtime.Runtime;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

typedef Sample = {
	final totalMs:Float;
	final compileMs:Float;
	final runtimeMs:Float;
	final artifactBytes:Int;
	final retyped:Int;
	final regenerated:Int;
	final transactionSnapshotMs:Float;
	final frontendMs:Float;
	final typingLoweringMs:Float;
	final irAssemblyMs:Float;
	final abiPlanningMs:Float;
	final backendAssemblyMs:Float;
	final patchEncodingMs:Float;
	final finalizeMs:Float;
}

typedef Summary = {
	final samples:Int;
	final totalMs:Percentiles;
	final compileMs:Percentiles;
	final runtimeMs:Percentiles;
	final artifactBytes:Percentiles;
	final retyped:Percentiles;
	final regenerated:Percentiles;
	final transactionSnapshotMs:Percentiles;
	final frontendMs:Percentiles;
	final typingLoweringMs:Percentiles;
	final irAssemblyMs:Percentiles;
	final abiPlanningMs:Percentiles;
	final backendAssemblyMs:Percentiles;
	final patchEncodingMs:Percentiles;
	final finalizeMs:Percentiles;
}

typedef Percentiles = {
	final median:Float;
	final p95:Float;
	final p99:Float;
}

class BenchmarkMain {
	static final fixtureRoot = "tests/fixtures/pragtical/";
	static final fixturePaths = [
		"pragtical/api/Plugin.hx",
		"pragtical/api/Document.hx",
		"pragtical/api/Editor.hx",
		"pragtical/plugins/PluginState.hx",
		"pragtical/plugins/SearchPlugin.hx",
		"Main.hx"
	];

	static function main():Void {
		var args = Sys.args(),
			iterations = intArg(args, "--iterations", 100),
			warmup = intArg(args, "--warmup", 10),
			soakIterations = intArg(args, "--soak", 1000),
			output = stringArg(args, "--json", "out/benchmark.json"),
			soakMode = stringArg(args, "--soak-mode", "combined"),
			onlySoak = args.indexOf("--only-soak") >= 0,
			onlyScale = args.indexOf("--only-scale") >= 0,
			scaleIterations = intArg(args, "--scale-iterations", 10);
		if (iterations < 1 || warmup < 0 || soakIterations < 1)
			throw "benchmark counts must be positive (warmup may be zero)";
		if (["combined", "compiler", "runtime"].indexOf(soakMode) < 0)
			throw "--soak-mode must be combined, compiler, or runtime";

		var results:Dynamic = {}, scenarios = [
			{name: "cold_compile_load", run: coldCompileLoad},
			{name: "noop_rebuild", run: noopRebuild},
			{name: "body_edit_patch", run: bodyEditPatch},
			{name: "signature_edit_reload", run: signatureEditReload},
			{name: "structural_edit_reload", run: structuralEditReload}
		];
		if (!onlySoak && !onlyScale)
			for (scenario in scenarios) {
				for (_ in 0...warmup)
					scenario.run();
				var samples = [for (_ in 0...iterations) scenario.run()];
				Reflect.setField(results, scenario.name, summarize(samples));
			}
		if (!onlyScale)
			Reflect.setField(results, soakMode + "_patch_soak", patchSoak(soakIterations, soakMode));
		if (onlyScale)
			for (size in parseSizes(stringArg(args, "--scales", "10,100,1000")))
				Reflect.setField(results, "scale_" + size, scaleBenchmark(size, scaleIterations));
		var report = {
			version: 1,
			generatedAt: Date.now().toString(),
			iterations: iterations,
			warmup: warmup,
			soakIterations: soakIterations,
			soakMode: soakMode,
			scaleIterations: onlyScale ? scaleIterations : 0,
			platform: Sys.systemName(),
			results: results
		};
		var directory = output.lastIndexOf("/") < 0 ? "." : output.substr(0, output.lastIndexOf("/"));
		if (!FileSystem.exists(directory))
			FileSystem.createDirectory(directory);
		File.saveContent(output, Json.stringify(report, null, "  ") + "\n");
		printSummary(results);
		Sys.println('JSON: $output');
	}

	static function coldCompileLoad():Sample {
		var started = stamp(),
			compiler = fixtureCompiler(),
			build = compiler.compile("Main"),
			compileDone = stamp(),
			bytes = HlWriter.encode(build.module),
			module = Runtime.load(bytes, build.runtimeIdentity);
		Runtime.dispose(module);
		return sample(started, compileDone, stamp(), bytes.length, build.metrics.retypedFunctions, build.metrics.regeneratedFunctions, build.metrics);
	}

	static function noopRebuild():Sample {
		var compiler = fixtureCompiler();
		compiler.compile("Main");
		var started = stamp(), build = compiler.compile("Main"), done = stamp();
		return sample(started, done, done, 0, build.metrics.retypedFunctions, build.metrics.regeneratedFunctions, build.metrics);
	}

	static function bodyEditPatch():Sample {
		var compiler = fixtureCompiler(),
			initial = compiler.compile("Main"),
			module = Runtime.load(HlWriter.encode(initial.module), initial.runtimeIdentity),
			source = fixture("pragtical/plugins/SearchPlugin.hx");
		compiler.update("pragtical/plugins/SearchPlugin.hx", StringTools.replace(source, "state.cursor + 1", "state.cursor + 2"));
		var started = stamp(),
			build = compiler.compile("Main"),
			compileDone = stamp();
		Runtime.patchSet(module, new PatchSet(initial.revision, build.revision, build.patchBytes, build.changedFunctions));
		var done = stamp();
		Runtime.dispose(module);
		return sample(started, compileDone, done, build.patchBytes.length, build.metrics.retypedFunctions, build.metrics.regeneratedFunctions, build.metrics);
	}

	static function signatureEditReload():Sample {
		var compiler = fixtureCompiler(),
			initial = compiler.compile("Main"),
			module = Runtime.load(HlWriter.encode(initial.module), initial.runtimeIdentity),
			plugin = fixture("pragtical/plugins/SearchPlugin.hx");
		plugin = StringTools.replace(plugin, "public function find():Int", "public function find(step:Int):Int");
		plugin = StringTools.replace(plugin, "state.cursor + 1", "state.cursor + step");
		plugin = StringTools.replace(plugin, "this.find()", "this.find(1)");
		compiler.update("pragtical/plugins/SearchPlugin.hx", plugin);
		return compileReload(compiler, module);
	}

	static function structuralEditReload():Sample {
		var compiler = fixtureCompiler(),
			initial = compiler.compile("Main"),
			module = Runtime.load(HlWriter.encode(initial.module), initial.runtimeIdentity),
			editor = fixture("pragtical/api/Editor.hx");
		compiler.update("pragtical/api/Editor.hx",
			StringTools.replace(editor, "public var documents:Array<Document>;", "public var documents:Array<Document>; public var generation:Int;"));
		return compileReload(compiler, module);
	}

	static function compileReload(compiler:Compiler, oldModule:LoadedModule):Sample {
		var started = stamp(), build = compiler.compile("Main"), compileDone = stamp(), bytes = HlWriter.encode(build.module),
			module = Runtime.load(bytes, build.runtimeIdentity), done = stamp();
		Runtime.dispose(oldModule);
		Runtime.dispose(module);
		return sample(started, compileDone, done, bytes.length, build.metrics.retypedFunctions, build.metrics.regeneratedFunctions, build.metrics);
	}

	static function patchSoak(iterations:Int, mode:String):Dynamic {
		var compiler = fixtureCompiler(),
			initial = compiler.compile("Main"),
			module = Runtime.load(HlWriter.encode(initial.module), initial.runtimeIdentity),
			source = fixture("pragtical/plugins/SearchPlugin.hx"),
			revision = initial.revision,
			samples:Array<Sample> = [];
		hl.Gc.major();
		var rssBefore = residentKb(), heapBefore = hl.Gc.stats().currentMemory;
		if (mode == "runtime") {
			var patches:Array<{
				base:Int,
				revision:Int,
				bytes:Bytes,
				functions:Array<Int>
			}> = [];
			for (i in 0...iterations) {
				var replacement = i % 2 == 0 ? "state.cursor + 2" : "state.cursor + 3";
				compiler.update("pragtical/plugins/SearchPlugin.hx", StringTools.replace(source, "state.cursor + 1", replacement));
				var build = compiler.compile("Main");
				patches.push({
					base: revision,
					revision: build.revision,
					bytes: build.patchBytes,
					functions: build.changedFunctions
				});
				revision = build.revision;
			}
			hl.Gc.major();
			rssBefore = residentKb();
			heapBefore = hl.Gc.stats().currentMemory;
			for (patch in patches) {
				var started = stamp();
				Runtime.patchSet(module, new PatchSet(patch.base, patch.revision, patch.bytes, patch.functions));
				samples.push(sample(started, started, stamp(), patch.bytes.length, 0, 0));
			}
			return finishSoak(samples, module, rssBefore, heapBefore);
		}
		for (i in 0...iterations) {
			var replacement = i % 2 == 0 ? "state.cursor + 2" : "state.cursor + 3";
			compiler.update("pragtical/plugins/SearchPlugin.hx", StringTools.replace(source, "state.cursor + 1", replacement));
			var started = stamp(),
				build = compiler.compile("Main"),
				compileDone = stamp();
			if (mode == "combined")
				Runtime.patchSet(module, new PatchSet(revision, build.revision, build.patchBytes, build.changedFunctions));
			samples.push(sample(started, compileDone, stamp(), build.patchBytes.length, build.metrics.retypedFunctions, build.metrics.regeneratedFunctions,
				build.metrics));
			revision = build.revision;
		}
		return finishSoak(samples, module, rssBefore, heapBefore);
	}

	static function finishSoak(samples:Array<Sample>, module:LoadedModule, rssBefore:Int, heapBefore:Float):Dynamic {
		hl.Gc.major();
		var rssAfter = residentKb(), result:Dynamic = summarize(samples);
		Reflect.setField(result, "rssBeforeKb", rssBefore);
		Reflect.setField(result, "rssAfterKb", rssAfter);
		Reflect.setField(result, "rssGrowthKb", rssAfter - rssBefore);
		Reflect.setField(result, "heapBeforeBytes", heapBefore);
		Reflect.setField(result, "heapAfterBytes", hl.Gc.stats().currentMemory);
		Reflect.setField(result, "heapGrowthBytes", hl.Gc.stats().currentMemory - heapBefore);
		Reflect.setField(result, "patchJitCount", Runtime.patchJitCount(module));
		Reflect.setField(result, "liveCodeAllocations", Runtime.liveAllocationCount(module));
		Reflect.setField(result, "retiredCodeAllocations", Runtime.retiredCodeAllocationCount(module));
		Runtime.dispose(module);
		return result;
	}

	static function fixtureCompiler():Compiler {
		var compiler = new Compiler();
		for (path in fixturePaths)
			compiler.update(path, fixture(path));
		return compiler;
	}

	static function scaleBenchmark(size:Int, iterations:Int):Dynamic {
		if (size < 3)
			throw "scale sizes must contain at least three modules";
		var result:Dynamic = {};
		for (scenario in [
			"cold_compile",
			"noop_rebuild",
			"leaf_body_edit",
			"central_body_edit",
			"broad_signature_edit"
		])
			Reflect.setField(result, scenario, summarize([for (_ in 0...iterations) scaleSample(size, scenario)]));
		Reflect.setField(result, "memory", scaleMemory(size));
		return result;
	}

	static function scaleMemory(size:Int):Dynamic {
		hl.Gc.major();
		var rssBefore = residentKb(),
			heapBefore = hl.Gc.stats().currentMemory,
			compiler = generatedCompiler(size);
		compiler.compile("Main");
		hl.Gc.major();
		var rssAfter = residentKb(), heapAfter = hl.Gc.stats().currentMemory;
		return {
			rssBeforeKb: rssBefore,
			rssAfterKb: rssAfter,
			rssGrowthKb: rssAfter - rssBefore,
			heapBeforeBytes: heapBefore,
			heapAfterBytes: heapAfter,
			heapGrowthBytes: heapAfter - heapBefore
		};
	}

	static function scaleSample(size:Int, scenario:String):Sample {
		var compiler = generatedCompiler(size), started = stamp();
		if (scenario != "cold_compile") {
			compiler.compile("Main");
			started = stamp();
			switch scenario {
				case "noop_rebuild":
				case "leaf_body_edit":
					compiler.update(nodePath(size - 3), "function value():Int { return Core.value() + 1; }");
				case "central_body_edit":
					compiler.update(nodePath(0), nodeSource(0, size - 2, true));
				case "broad_signature_edit":
					compiler.update("Core.hx", "function value(offset:Int):Int { return 1 + offset; }");
					for (index in 0...(size - 2))
						if (isLeaf(index, size - 2))
							compiler.update(nodePath(index), "function value():Int { return Core.value(0); }");
				default:
			}
		}
		var build = compiler.compile("Main"),
			compileDone = stamp(),
			artifactBytes = scenario == "cold_compile" ? HlWriter.encode(build.module)
				.length : build.patchBytes != null ? build.patchBytes.length : build.changedFunctions.length == 0
					&& !build.requiresReload ? 0 : HlWriter.encode(build.module).length;
		return sample(started, compileDone, compileDone, artifactBytes, build.metrics.retypedFunctions, build.metrics.regeneratedFunctions, build.metrics);
	}

	static function generatedCompiler(size:Int):Compiler {
		var compiler = new Compiler(), nodes = size - 2;
		compiler.update("Core.hx", "function value():Int { return 1; }");
		for (index in 0...nodes)
			compiler.update(nodePath(index), nodeSource(index, nodes, false));
		compiler.update("Main.hx", "function main():Int { return Node0.value(); }");
		return compiler;
	}

	static function nodeSource(index:Int, nodes:Int, changed:Bool):String {
		var left = index * 2 + 1, right = left + 1;
		if (left >= nodes)
			return "function value():Int { return Core.value(); }";
		var expression = "Node" + left + ".value()";
		if (right < nodes)
			expression += " + Node" + right + ".value()";
		if (changed)
			expression += " + 1";
		return "function value():Int { return " + expression + "; }";
	}

	static function isLeaf(index:Int, nodes:Int):Bool
		return index * 2 + 1 >= nodes;

	static function nodePath(index:Int):String
		return "Node" + index + ".hx";

	static function parseSizes(value:String):Array<Int> {
		var result:Array<Int> = [];
		for (part in value.split(",")) {
			var size = Std.parseInt(StringTools.trim(part));
			if (size == null || size < 3)
				throw 'invalid scale size "$part"';
			result.push(size);
		}
		return result;
	}

	static function fixture(path:String):String {
		var diskPath = path == "Main.hx" ? fixtureRoot + "pragtical/app/Main.hx" : fixtureRoot + path;
		return File.getContent(diskPath);
	}

	static function sample(started:Float, compileDone:Float, done:Float, bytes:Int, retyped:Int, regenerated:Int, ?metrics:CompileMetrics):Sample
		return {
			totalMs: (done - started) * 1000.0,
			compileMs: (compileDone - started) * 1000.0,
			runtimeMs: (done - compileDone) * 1000.0,
			artifactBytes: bytes,
			retyped: retyped,
			regenerated: regenerated,
			transactionSnapshotMs: metrics == null ? 0.0 : metrics.transactionSnapshotMs,
			frontendMs: metrics == null ? 0.0 : metrics.frontendMs,
			typingLoweringMs: metrics == null ? 0.0 : metrics.typingLoweringMs,
			irAssemblyMs: metrics == null ? 0.0 : metrics.irAssemblyMs,
			abiPlanningMs: metrics == null ? 0.0 : metrics.abiPlanningMs,
			backendAssemblyMs: metrics == null ? 0.0 : metrics.backendAssemblyMs,
			patchEncodingMs: metrics == null ? 0.0 : metrics.patchEncodingMs,
			finalizeMs: metrics == null ? 0.0 : metrics.finalizeMs
		};

	static function summarize(samples:Array<Sample>):Summary
		return {
			samples: samples.length,
			totalMs: percentiles([for (value in samples) value.totalMs]),
			compileMs: percentiles([for (value in samples) value.compileMs]),
			runtimeMs: percentiles([for (value in samples) value.runtimeMs]),
			artifactBytes: percentiles([for (value in samples) value.artifactBytes]),
			retyped: percentiles([for (value in samples) value.retyped]),
			regenerated: percentiles([for (value in samples) value.regenerated]),
			transactionSnapshotMs: percentiles([for (value in samples) value.transactionSnapshotMs]),
			frontendMs: percentiles([for (value in samples) value.frontendMs]),
			typingLoweringMs: percentiles([for (value in samples) value.typingLoweringMs]),
			irAssemblyMs: percentiles([for (value in samples) value.irAssemblyMs]),
			abiPlanningMs: percentiles([for (value in samples) value.abiPlanningMs]),
			backendAssemblyMs: percentiles([for (value in samples) value.backendAssemblyMs]),
			patchEncodingMs: percentiles([for (value in samples) value.patchEncodingMs]),
			finalizeMs: percentiles([for (value in samples) value.finalizeMs])
		};

	static function percentiles(values:Array<Float>):Percentiles {
		values.sort((left, right) -> left < right ? -1 : left > right ? 1 : 0);
		return {median: percentile(values, 0.50), p95: percentile(values, 0.95), p99: percentile(values, 0.99)};
	}

	static function percentile(values:Array<Float>, quantile:Float):Float
		return values[Math.ceil(quantile * values.length) - 1];

	static function printSummary(results:Dynamic):Void {
		Sys.println("scenario                    median ms    p95 ms    p99 ms    bytes");
		for (name in Reflect.fields(results)) {
			var result:Dynamic = Reflect.field(results, name),
				total:Dynamic = Reflect.field(result, "totalMs"),
				bytes:Dynamic = Reflect.field(result, "artifactBytes");
			if (total == null) {
				for (scenario in Reflect.fields(result))
					if (Reflect.hasField(Reflect.field(result, scenario), "totalMs"))
						printSummaryRow(name + "/" + scenario, Reflect.field(result, scenario));
				continue;
			}
			printSummaryRow(name, result);
		}
	}

	static function printSummaryRow(name:String, result:Dynamic):Void {
		var total:Dynamic = Reflect.field(result, "totalMs"),
			bytes:Dynamic = Reflect.field(result, "artifactBytes");
		Sys.println(StringTools.rpad(name, " ", 28) + StringTools.lpad(format(total.median), " ", 10) + StringTools.lpad(format(total.p95), " ", 10)
			+ StringTools.lpad(format(total.p99), " ", 10) + StringTools.lpad(format(bytes.median), " ", 9));
	}

	static function format(value:Float):String
		return Std.string(Math.round(value * 100.0) / 100.0);

	static function stamp():Float
		return Sys.time();

	static function residentKb():Int {
		var process:Process = null;
		try {
			process = new Process("sh", ["-c", "ps -o rss= -p $PPID"]);
			var value = Std.parseInt(StringTools.trim(process.stdout.readAll().toString()));
			process.close();
			return value == null ? -1 : value;
		} catch (_:Dynamic) {
			if (process != null)
				process.close();
			return -1;
		}
	}

	static function intArg(args:Array<String>, name:String, fallback:Int):Int {
		var value = stringArg(args, name, null);
		return value == null ? fallback : Std.parseInt(value);
	}

	static function stringArg(args:Array<String>, name:String, fallback:String):String {
		var index = args.indexOf(name);
		return index < 0 || index + 1 >= args.length ? fallback : args[index + 1];
	}
}
