package;

import compiler.service.LanguageService;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

private typedef Sample = {
	final updateMs:Float;
	final completionMs:Float;
	final signatureMs:Float;
	final hoverMs:Float;
	final definitionMs:Float;
	final analysisMs:Float;
	final recoveredSnapshots:Int;
	final workspaceUpdateMs:Float;
	final workspaceCompletionMs:Float;
	final malformedUpdateMs:Float;
	final malformedCompletionMs:Float;
	final totalMs:Float;
}

private typedef Percentiles = {
	final median:Float;
	final p95:Float;
	final p99:Float;
}

private typedef ScaledSample = {
	final updateMs:Float;
	final completionMs:Float;
}

private typedef ProjectSample = {
	final updateMs:Float;
	final completionMs:Float;
	final definitionMs:Float;
	final malformedUpdateMs:Float;
	final malformedCompletionMs:Float;
}

/** Measures editor recovery latency and memory growth under rapid edits. */
class LanguageServiceBenchmarkMain {
	static final prefix = "class Foo { public function bar(value:Int):Int return value; }\n" + "function main():Void { var foo:Foo = new Foo(); ";
	static final tails = [
		"f",
		"fo",
		"foo",
		"foo.",
		"foo.b",
		"foo.ba",
		"foo.bar(",
		"foo.bar(x",
		"foo.bar(x)"
	];

	static function main():Void {
		var args = Sys.args(),
			iterations = intArg(args, "--iterations", 100),
			warmup = intArg(args, "--warmup", 10),
			projectIterations = intArg(args, "--project-iterations", 5),
			scaleIterations = intArg(args, "--scale-iterations", 3),
			scaleModules = intArg(args, "--scale-modules", 64),
			enduranceEdits = intArg(args, "--endurance-edits", 250),
			output = stringArg(args, "--json", "out/editor-benchmark.json"),
			checkBudgets = hasFlag(args, "--check-budgets");
		if (iterations < 1 || warmup < 0 || projectIterations < 1 || scaleIterations < 1 || scaleModules < 1 || enduranceEdits < 1)
			throw "iterations and scale parameters must be positive; warmup cannot be negative";

		for (_ in 0...warmup)
			runIteration();
		for (_ in 0...warmup)
			runPragticalProjectScenario();
		var before = processMemory(),
			samples = [for (_ in 0...iterations) runIteration()],
			projectSamples = [for (_ in 0...projectIterations) runPragticalProjectScenario()],
			after = processMemory(),
			scaleSamples = [for (_ in 0...scaleIterations) runScaledWorkspaceScenario(scaleModules)],
			longLivedMemoryGrowth = runLongLivedScenario(scaleModules, enduranceEdits);
		var report = {
			version: 4,
			iterations: iterations,
			warmup: warmup,
			projectIterations: projectIterations,
			platform: Sys.systemName(),
			memoryBeforeBytes: before,
			memoryAfterBytes: after,
			memoryGrowthBytes: after < 0 || before < 0 ? -1 : after - before,
			updateMs: percentiles([for (sample in samples) sample.updateMs]),
			completionMs: percentiles([for (sample in samples) sample.completionMs]),
			signatureMs: percentiles([for (sample in samples) sample.signatureMs]),
			hoverMs: percentiles([for (sample in samples) sample.hoverMs]),
			definitionMs: percentiles([for (sample in samples) sample.definitionMs]),
			analysisMs: percentiles([for (sample in samples) sample.analysisMs]),
			workspaceUpdateMs: percentiles([for (sample in samples) sample.workspaceUpdateMs]),
			workspaceCompletionMs: percentiles([for (sample in samples) sample.workspaceCompletionMs]),
			malformedUpdateMs: percentiles([for (sample in samples) sample.malformedUpdateMs]),
			malformedCompletionMs: percentiles([for (sample in samples) sample.malformedCompletionMs]),
			pragticalProjectUpdateMs: percentiles([for (sample in projectSamples) sample.updateMs]),
			pragticalProjectCompletionMs: percentiles([for (sample in projectSamples) sample.completionMs]),
			pragticalProjectDefinitionMs: percentiles([for (sample in projectSamples) sample.definitionMs]),
			pragticalProjectMalformedUpdateMs: percentiles([for (sample in projectSamples) sample.malformedUpdateMs]),
			pragticalProjectMalformedCompletionMs: percentiles([for (sample in projectSamples) sample.malformedCompletionMs]),
			scaleModules: scaleModules,
			scaleIterations: scaleIterations,
			scaledWorkspaceUpdateMs: percentiles([for (sample in scaleSamples) sample.updateMs]),
			scaledWorkspaceCompletionMs: percentiles([for (sample in scaleSamples) sample.completionMs]),
			enduranceEdits: enduranceEdits,
			longLivedMemoryGrowthBytes: longLivedMemoryGrowth,
			recoveredSnapshots: {
				total: sumSnapshots(samples),
				average: sumSnapshots(samples) / samples.length
			},
			totalMs: percentiles([for (sample in samples) sample.totalMs])
		};
		var separator = output.lastIndexOf("/");
		if (separator > 0) {
			var directory = output.substring(0, separator);
			if (!FileSystem.exists(directory))
				FileSystem.createDirectory(directory);
		}
		File.saveContent(output, Json.stringify(report, null, "  ") + "\n");
		Sys.println('Editor benchmark: ${iterations} iterations, memory growth ${report.memoryGrowthBytes} bytes');
		Sys.println('Update median/p95/p99: ${format(report.updateMs.median)}/${format(report.updateMs.p95)}/${format(report.updateMs.p99)} ms');
		Sys.println('Completion median/p95/p99: ${format(report.completionMs.median)}/${format(report.completionMs.p95)}/${format(report.completionMs.p99)} ms');
		Sys.println('Signature median/p95/p99: ${format(report.signatureMs.median)}/${format(report.signatureMs.p95)}/${format(report.signatureMs.p99)} ms');
		Sys.println('Hover median/p95/p99: ${format(report.hoverMs.median)}/${format(report.hoverMs.p95)}/${format(report.hoverMs.p99)} ms');
		Sys.println('Definition median/p95/p99: ${format(report.definitionMs.median)}/${format(report.definitionMs.p95)}/${format(report.definitionMs.p99)} ms');
		Sys.println('Analysis median/p95/p99: ${format(report.analysisMs.median)}/${format(report.analysisMs.p95)}/${format(report.analysisMs.p99)} ms');
		Sys.println('Workspace update median/p95/p99: ${format(report.workspaceUpdateMs.median)}/${format(report.workspaceUpdateMs.p95)}/${format(report.workspaceUpdateMs.p99)} ms');
		Sys.println('Workspace completion median/p95/p99: ${format(report.workspaceCompletionMs.median)}/${format(report.workspaceCompletionMs.p95)}/${format(report.workspaceCompletionMs.p99)} ms');
		Sys.println('Malformed update median/p95/p99: ${format(report.malformedUpdateMs.median)}/${format(report.malformedUpdateMs.p95)}/${format(report.malformedUpdateMs.p99)} ms');
		Sys.println('Malformed completion median/p95/p99: ${format(report.malformedCompletionMs.median)}/${format(report.malformedCompletionMs.p95)}/${format(report.malformedCompletionMs.p99)} ms');
		Sys.println('Pragtical fixture update median/p95/p99: ${format(report.pragticalProjectUpdateMs.median)}/${format(report.pragticalProjectUpdateMs.p95)}/${format(report.pragticalProjectUpdateMs.p99)} ms');
		Sys.println('Pragtical fixture completion median/p95/p99: ${format(report.pragticalProjectCompletionMs.median)}/${format(report.pragticalProjectCompletionMs.p95)}/${format(report.pragticalProjectCompletionMs.p99)} ms');
		Sys.println('Pragtical fixture definition median/p95/p99: ${format(report.pragticalProjectDefinitionMs.median)}/${format(report.pragticalProjectDefinitionMs.p95)}/${format(report.pragticalProjectDefinitionMs.p99)} ms');
		Sys.println('Pragtical fixture malformed update median/p95/p99: ${format(report.pragticalProjectMalformedUpdateMs.median)}/${format(report.pragticalProjectMalformedUpdateMs.p95)}/${format(report.pragticalProjectMalformedUpdateMs.p99)} ms');
		Sys.println('Pragtical fixture malformed completion median/p95/p99: ${format(report.pragticalProjectMalformedCompletionMs.median)}/${format(report.pragticalProjectMalformedCompletionMs.p95)}/${format(report.pragticalProjectMalformedCompletionMs.p99)} ms');
		Sys.println('Scaled workspace (${scaleModules} modules) update median/p95/p99: ${format(report.scaledWorkspaceUpdateMs.median)}/${format(report.scaledWorkspaceUpdateMs.p95)}/${format(report.scaledWorkspaceUpdateMs.p99)} ms');
		Sys.println('Scaled workspace completion median/p95/p99: ${format(report.scaledWorkspaceCompletionMs.median)}/${format(report.scaledWorkspaceCompletionMs.p95)}/${format(report.scaledWorkspaceCompletionMs.p99)} ms');
		Sys.println('Long-lived memory growth after ${enduranceEdits} edits: ${report.longLivedMemoryGrowthBytes} bytes');
		Sys.println('Recovered snapshots average: ${format(report.recoveredSnapshots.average)}');
		if (checkBudgets) {
			enforceBudgets(report);
			Sys.println("Budget check: passed");
		}
		Sys.println('JSON: $output');
	}

	/**
	 * Conservative p95 budgets for the small multi-module editor workload above.
	 * The check is opt-in so ordinary benchmark runs can still be used to compare
	 * hardware and compiler changes without turning timing noise into failures.
	 */
	static function enforceBudgets(report:Dynamic):Void {
		checkBudget("edit-to-recovery", report.updateMs.p95, 100.0);
		checkBudget("completion", report.completionMs.p95, 100.0);
		checkBudget("signature-help", report.signatureMs.p95, 100.0);
		checkBudget("hover", report.hoverMs.p95, 100.0);
		checkBudget("definition", report.definitionMs.p95, 100.0);
		checkBudget("background-analysis", report.analysisMs.p95, 500.0);
		checkBudget("workspace-edit-to-recovery", report.workspaceUpdateMs.p95, 100.0);
		checkBudget("workspace-completion", report.workspaceCompletionMs.p95, 100.0);
		checkBudget("malformed-edit-to-recovery", report.malformedUpdateMs.p95, 100.0);
		checkBudget("malformed-completion", report.malformedCompletionMs.p95, 100.0);
		checkBudget("Pragtical-fixture-edit-to-recovery", report.pragticalProjectUpdateMs.p95, 100.0);
		checkBudget("Pragtical-fixture-completion", report.pragticalProjectCompletionMs.p95, 100.0);
		checkBudget("Pragtical-fixture-definition", report.pragticalProjectDefinitionMs.p95, 100.0);
		checkBudget("Pragtical-fixture-malformed-edit-to-recovery", report.pragticalProjectMalformedUpdateMs.p95, 100.0);
		checkBudget("Pragtical-fixture-malformed-completion", report.pragticalProjectMalformedCompletionMs.p95, 100.0);
		checkBudget("scaled-workspace-edit-to-recovery", report.scaledWorkspaceUpdateMs.p95, 500.0);
		checkBudget("scaled-workspace-completion", report.scaledWorkspaceCompletionMs.p95, 500.0);
		var memoryGrowth:Float = report.memoryGrowthBytes;
		if (memoryGrowth >= 0 && memoryGrowth > 32.0 * 1024.0 * 1024.0)
			throw 'Editor benchmark memory-growth budget exceeded: ${memoryGrowth} bytes > ${32 * 1024 * 1024} bytes';
		var longLivedMemoryGrowth:Float = report.longLivedMemoryGrowthBytes;
		if (longLivedMemoryGrowth >= 0 && longLivedMemoryGrowth > 128.0 * 1024.0 * 1024.0)
			throw 'Long-lived editor memory-growth budget exceeded: ${longLivedMemoryGrowth} bytes > ${128 * 1024 * 1024} bytes';
	}

	static function checkBudget(name:String, value:Float, limit:Float):Void {
		if (value > limit)
			throw 'Editor benchmark $name budget exceeded: ${format(value)} ms > ${format(limit)} ms';
	}

	static function runIteration():Sample {
		var service = new LanguageService(), updateMs = 0.0, completionMs = 0.0, signatureMs = 0.0, hoverMs = 0.0, definitionMs = 0.0, analysisMs = 0.0,
			started = Sys.time();
		for (tail in tails) {
			var source = prefix + tail, editStarted = Sys.time();
			var state = service.update("EditorBenchmark.hx", source);
			if (state.recoveredSemanticModel == null)
				throw 'editor update did not build a recovered snapshot for "$tail"';
			updateMs += (Sys.time() - editStarted) * 1000.0;
			var queryStarted = Sys.time();
			service.completeResult("EditorBenchmark.hx", source.length);
			completionMs += (Sys.time() - queryStarted) * 1000.0;
			if (tail == "foo.bar(" || tail == "foo.bar(x") {
				queryStarted = Sys.time();
				service.signatureHelp("EditorBenchmark.hx", source.length);
				signatureMs += (Sys.time() - queryStarted) * 1000.0;
			}
		}
		var probe = (prefix + tails[tails.length - 1]).lastIndexOf("foo.bar") + 1,
			queryStarted = Sys.time();
		service.hover("EditorBenchmark.hx", probe);
		hoverMs = (Sys.time() - queryStarted) * 1000.0;
		queryStarted = Sys.time();
		service.definition("EditorBenchmark.hx", probe);
		definitionMs = (Sys.time() - queryStarted) * 1000.0;
		queryStarted = Sys.time();
		try
			service.analyze("EditorBenchmark")
		catch (_:Dynamic) {}
		analysisMs = (Sys.time() - queryStarted) * 1000.0;
		var workspace = runWorkspaceScenario();
		return {
			updateMs: updateMs,
			completionMs: completionMs,
			signatureMs: signatureMs,
			hoverMs: hoverMs,
			definitionMs: definitionMs,
			analysisMs: analysisMs,
			recoveredSnapshots: service.recoveredSnapshotBuilds,
			workspaceUpdateMs: workspace.workspaceUpdateMs,
			workspaceCompletionMs: workspace.workspaceCompletionMs,
			malformedUpdateMs: workspace.malformedUpdateMs,
			malformedCompletionMs: workspace.malformedCompletionMs,
			totalMs: (Sys.time() - started) * 1000.0
		};
	}

	static function runWorkspaceScenario():{
		workspaceUpdateMs:Float,
		workspaceCompletionMs:Float,
		malformedUpdateMs:Float,
		malformedCompletionMs:Float
	} {
		var service = new LanguageService();
		service.update("bench/Foo.hx", "package bench; class Foo { public var knownFoo:Int; }");
		var source = "package bench; function main():Int { var foo:Foo = new Foo(); return foo. }",
			started = Sys.time();
		service.update("bench/Main.hx", source);
		var workspaceUpdateMs = (Sys.time() - started) * 1000.0;
		started = Sys.time();
		var completion = service.completeResult("bench/Main.hx", source.lastIndexOf("foo.") + "foo.".length);
		var workspaceCompletionMs = (Sys.time() - started) * 1000.0;
		if (!completion.isIncomplete || !hasLabel(completion.items, "knownFoo"))
			throw "multi-module recovery benchmark lost current member completion";
		var malformed = "package bench; function main():Int { var foo:Foo = new Foo(); broken.unresolved().thing; return foo. }";
		started = Sys.time();
		service.update("bench/Main.hx", malformed);
		var malformedUpdateMs = (Sys.time() - started) * 1000.0;
		started = Sys.time();
		completion = service.completeResult("bench/Main.hx", malformed.lastIndexOf("foo.") + "foo.".length);
		var malformedCompletionMs = (Sys.time() - started) * 1000.0;
		if (!completion.isIncomplete || !hasLabel(completion.items, "knownFoo"))
			throw "malformed multi-module recovery benchmark lost member completion";
		return {
			workspaceUpdateMs: workspaceUpdateMs,
			workspaceCompletionMs: workspaceCompletionMs,
			malformedUpdateMs: malformedUpdateMs,
			malformedCompletionMs: malformedCompletionMs
		};
	}

	static function runPragticalProjectScenario():ProjectSample {
		var service = new LanguageService(),
			fixtureRoot = "tests/fixtures/pragtical/",
			paths = [
				"pragtical/api/Plugin.hx",
				"pragtical/api/Document.hx",
				"pragtical/api/Editor.hx",
				"pragtical/plugins/PluginState.hx",
				"pragtical/plugins/SearchPlugin.hx",
				"pragtical/app/Main.hx"
			],
			pluginPath = "pragtical/plugins/SearchPlugin.hx",
			plugin = File.getContent(fixtureRoot + pluginPath);
		for (path in paths)
			service.update(path, File.getContent(fixtureRoot + path));
		service.compile("pragtical.app.Main");
		var mainPath = "pragtical/app/Main.hx",
			mainSource = File.getContent(fixtureRoot + mainPath),
			mainPosition = mainSource.indexOf("searchPlugin.activate") + "searchPlugin.".length + 1,
			started = Sys.time();
		service.update(mainPath, mainSource + " ");
		var updateMs = (Sys.time() - started) * 1000.0;
		started = Sys.time();
		var completion = service.completeResult(mainPath, mainSource.length);
		var completionMs = (Sys.time() - started) * 1000.0;
		if (!hasLabel(completion.items, "runCommand"))
			throw "Pragtical fixture completion lost current host symbols";
		started = Sys.time();
		var definition = service.definition(mainPath, mainPosition);
		var definitionMs = (Sys.time() - started) * 1000.0;
		if (definition == null)
			throw "Pragtical fixture definition query lost SearchPlugin identity";
		var malformed = StringTools.replace(plugin, "return state.cursor;", "return state.");
		started = Sys.time();
		service.update(pluginPath, malformed);
		var malformedUpdateMs = (Sys.time() - started) * 1000.0,
			malformedPosition = malformed.lastIndexOf("state.") + "state.".length;
		started = Sys.time();
		var malformedCompletion = service.completeResult(pluginPath, malformedPosition);
		var malformedCompletionMs = (Sys.time() - started) * 1000.0;
		if (!malformedCompletion.isIncomplete || !hasLabel(malformedCompletion.items, "cursor"))
			throw "Pragtical fixture malformed completion lost current state members";
		return {
			updateMs: updateMs,
			completionMs: completionMs,
			definitionMs: definitionMs,
			malformedUpdateMs: malformedUpdateMs,
			malformedCompletionMs: malformedCompletionMs
		};
	}

	static function runScaledWorkspaceScenario(moduleCount:Int):ScaledSample {
		var service = prepareScaledWorkspace(moduleCount),
			source = scaledSource(moduleCount, 0),
			started = Sys.time();
		service.update("scale/Main.hx", source);
		var updateMs = (Sys.time() - started) * 1000.0;
		started = Sys.time();
		var completion = service.completeResult("scale/Main.hx", source.length),
			completionMs = (Sys.time() - started) * 1000.0;
		if (!completion.isIncomplete || !hasLabel(completion.items, "known0"))
			throw 'scaled workspace recovery lost member completion across $moduleCount modules';
		return {updateMs: updateMs, completionMs: completionMs};
	}

	static function runLongLivedScenario(moduleCount:Int, edits:Int):Float {
		var service = prepareScaledWorkspace(moduleCount),
			before = processMemory();
		for (edit in 0...edits) {
			var source = scaledSource(moduleCount, edit);
			service.update("scale/Main.hx", source);
			service.completeResult("scale/Main.hx", source.length);
		}
		var after = processMemory();
		return before < 0 || after < 0 ? -1 : after - before;
	}

	static function prepareScaledWorkspace(moduleCount:Int):LanguageService {
		var service = new LanguageService();
		for (index in 0...moduleCount)
			service.update('scale/Type$index.hx', 'package scale; class Type$index { public var known$index:Int; public function method$index(value:Int):Int return value; }');
		return service;
	}

	static function scaledSource(moduleCount:Int, edit:Int):String {
		var imports = [for (index in 0...moduleCount) 'import scale.Type$index;'].join(" ");
		return 'package scale; $imports function main():Int { var value:Type0 = new Type0(); broken$edit.unresolved().thing; return value.';
	}

	static function hasLabel(items:Array<compiler.service.LanguageService.CompletionItem>, label:String):Bool {
		for (item in items)
			if (item.label == label)
				return true;
		return false;
	}

	static function percentiles(values:Array<Float>):Percentiles {
		values.sort(Reflect.compare);
		return {
			median: percentile(values, 0.5),
			p95: percentile(values, 0.95),
			p99: percentile(values, 0.99)
		};
	}

	static function sumSnapshots(samples:Array<Sample>):Int {
		var result = 0;
		for (sample in samples)
			result += sample.recoveredSnapshots;
		return result;
	}

	static function percentile(values:Array<Float>, fraction:Float):Float {
		var index = Std.int(Math.ceil(values.length * fraction)) - 1;
		if (index < 0)
			index = 0;
		if (index >= values.length)
			index = values.length - 1;
		return values[index];
	}

	static function processMemory():Float {
		var process:Process = null;
		try {
			process = new Process("sh", ["-c", "ps -o rss= -p $PPID"]);
			var residentKb = Std.parseInt(StringTools.trim(process.stdout.readAll().toString()));
			process.close();
			return residentKb == null ? -1 : residentKb * 1024.0;
		} catch (_:Dynamic) {
			if (process != null)
				process.close();
			return -1;
		}
	}

	static function format(value:Float):String
		return Std.string(Math.round(value * 100.0) / 100.0);

	static function intArg(args:Array<String>, name:String, fallback:Int):Int {
		var value = stringArg(args, name, null);
		return value == null ? fallback : Std.parseInt(value);
	}

	static function stringArg(args:Array<String>, name:String, fallback:Null<String>):Null<String> {
		var prefix = name + "=";
		for (argument in args)
			if (StringTools.startsWith(argument, prefix))
				return argument.substring(prefix.length);
		return fallback;
	}

	static function hasFlag(args:Array<String>, name:String):Bool {
		for (argument in args)
			if (argument == name)
				return true;
		return false;
	}
}
