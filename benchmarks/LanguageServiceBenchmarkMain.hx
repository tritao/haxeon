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

private typedef ScenarioSample = {
	final updateMs:Float;
	final completionMs:Float;
	final definitionMs:Float;
	final malformedUpdateMs:Float;
	final malformedCompletionMs:Float;
	final repairedUpdateMs:Float;
	final repairedCompletionMs:Float;
	final modulesInvalidated:Int;
	final modulesAnalyzed:Int;
	final retypedFunctions:Int;
	final recoveredSnapshots:Int;
}

private typedef GeneratedSample = {
	final topology:String;
	final moduleCount:Int;
	final updateMs:Float;
	final completionMs:Float;
	final modulesInvalidated:Int;
	final modulesAnalyzed:Int;
	final retypedFunctions:Int;
	final recoveredSnapshots:Int;
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
			scenarioIterations = intArg(args, "--scenario-iterations", 5),
			scaleIterations = intArg(args, "--scale-iterations", 3),
			scaleModules = intArg(args, "--scale-modules", 64),
			scaleTopology = stringArg(args, "--scale-topology", "fanout"),
			enduranceEdits = intArg(args, "--endurance-edits", 250),
			output = stringArg(args, "--json", "out/editor-benchmark.json"),
			checkBudgets = hasFlag(args, "--check-budgets");
		if (iterations < 1 || warmup < 0 || scenarioIterations < 1 || scaleIterations < 1 || scaleModules < 1 || enduranceEdits < 1)
			throw "iterations and scale parameters must be positive; warmup cannot be negative";
		if (scaleTopology != "fanout" && scaleTopology != "chain" && scaleTopology != "diamond")
			throw 'unsupported generated workspace topology "$scaleTopology"';

		for (_ in 0...warmup)
			runIteration();
		for (_ in 0...warmup)
			runSmallProjectScenario();
		collectGarbage();
		var benchmarkService = new LanguageService(),
			benchmarkWorkspaceService = new LanguageService(),
			before = processMemory(),
			samples = [for (_ in 0...iterations) runIteration(benchmarkService, benchmarkWorkspaceService)],
			scenarioSamples = [for (_ in 0...scenarioIterations) runSmallProjectScenario()];
		collectGarbage();
		var after = processMemory(),
			generatedSamples = [for (_ in 0...scaleIterations) runGeneratedWorkspaceScenario(scaleModules, scaleTopology)],
			longLivedMemoryGrowth = runLongLivedScenario(scaleModules, enduranceEdits, scaleTopology),
			scenarios:Dynamic = {};
		Reflect.setField(scenarios, "small-project", summarizeScenario(scenarioSamples));
		Reflect.setField(scenarios, 'generated-$scaleModules-$scaleTopology', summarizeGenerated(generatedSamples));
		var report = {
			version: 5,
			iterations: iterations,
			warmup: warmup,
			scenarioIterations: scenarioIterations,
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
			scaleModules: scaleModules,
			scaleTopology: scaleTopology,
			scaleIterations: scaleIterations,
			scenarios: scenarios,
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
		printScenarioSummary("small-project", Reflect.field(scenarios, "small-project"));
		printScenarioSummary('generated-$scaleModules-$scaleTopology', Reflect.field(scenarios, 'generated-$scaleModules-$scaleTopology'));
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
		for (name in Reflect.fields(report.scenarios)) {
			var scenario:Dynamic = Reflect.field(report.scenarios, name),
				limit = StringTools.startsWith(name, "generated-") ? 500.0 : 100.0;
			checkBudget('$name edit-to-recovery', scenario.updateMs.p95, limit);
			checkBudget('$name completion', scenario.completionMs.p95, limit);
			if (Reflect.hasField(scenario, "malformedUpdateMs")) {
				checkBudget('$name malformed-edit-to-recovery', scenario.malformedUpdateMs.p95, limit);
				checkBudget('$name malformed-completion', scenario.malformedCompletionMs.p95, limit);
				checkBudget('$name repaired-edit-to-recovery', scenario.repairedUpdateMs.p95, limit);
				checkBudget('$name repaired-completion', scenario.repairedCompletionMs.p95, limit);
			}
		}
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

	static function runIteration(?sharedService:LanguageService, ?sharedWorkspaceService:LanguageService):Sample {
		var service = sharedService == null ? new LanguageService() : sharedService,
			recoveredSnapshotsBefore = service.recoveredSnapshotBuilds,
			updateMs = 0.0, completionMs = 0.0, signatureMs = 0.0, hoverMs = 0.0, definitionMs = 0.0, analysisMs = 0.0,
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
		var workspace = runWorkspaceScenario(sharedWorkspaceService);
		return {
			updateMs: updateMs,
			completionMs: completionMs,
			signatureMs: signatureMs,
			hoverMs: hoverMs,
			definitionMs: definitionMs,
			analysisMs: analysisMs,
			recoveredSnapshots: service.recoveredSnapshotBuilds - recoveredSnapshotsBefore,
			workspaceUpdateMs: workspace.workspaceUpdateMs,
			workspaceCompletionMs: workspace.workspaceCompletionMs,
			malformedUpdateMs: workspace.malformedUpdateMs,
			malformedCompletionMs: workspace.malformedCompletionMs,
			totalMs: (Sys.time() - started) * 1000.0
		};
	}

	static function runWorkspaceScenario(?sharedService:LanguageService):{
		workspaceUpdateMs:Float,
		workspaceCompletionMs:Float,
		malformedUpdateMs:Float,
		malformedCompletionMs:Float
	} {
		var service = sharedService == null ? new LanguageService() : sharedService;
		if (!service.compiler.modules.exists("bench.Foo"))
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

	static function runSmallProjectScenario():ScenarioSample {
		var service = new LanguageService(),
			fixtureRoot = "tests/fixtures/workspace-small/",
			pluginPath = "workspace/plugins/SearchPlugin.hx",
			plugin = File.getContent(fixtureRoot + pluginPath);
		for (absolutePath in fixtureSourcePaths(fixtureRoot + "workspace")) {
			var path = absolutePath.substring(fixtureRoot.length);
			service.update(path, File.getContent(absolutePath));
		}
		service.compile("workspace.app.Main");
		var mainPath = "workspace/app/Main.hx",
			mainSource = File.getContent(fixtureRoot + mainPath),
			mainPosition = mainSource.indexOf("searchPlugin.activate") + "searchPlugin.".length + 1,
			bodySource = StringTools.replace(mainSource, 'return current.execute("find");', 'return current.execute("find") + 0;');
		service.update(mainPath, bodySource);
		var bodyAnalysis = service.analyze("workspace.app.Main"),
			recoveredBefore = service.recoveredSnapshotBuilds,
			currentSource = StringTools.replace(bodySource, 'return current.execute("find") + 0;', "return current."),
			started = Sys.time();
		service.update(mainPath, currentSource);
		var updateMs = (Sys.time() - started) * 1000.0,
			currentPosition = currentSource.lastIndexOf("current.") + "current.".length;
		started = Sys.time();
		var completion = service.completeResult(mainPath, currentPosition);
		var completionMs = (Sys.time() - started) * 1000.0;
		if (!completion.isIncomplete || !hasLabel(completion.items, "execute"))
			throw "small project completion lost current editor members";
		started = Sys.time();
		var definition = service.definition(mainPath, mainPosition);
		var definitionMs = (Sys.time() - started) * 1000.0;
		if (definition == null)
			throw "small project definition query lost SearchPlugin identity";
		var malformed = StringTools.replace(plugin, "return current.cursor;", "return current.");
		started = Sys.time();
		service.update(pluginPath, malformed);
		var malformedUpdateMs = (Sys.time() - started) * 1000.0,
			malformedPosition = malformed.lastIndexOf("current.") + "current.".length;
		started = Sys.time();
		var malformedCompletion = service.completeResult(pluginPath, malformedPosition);
		var malformedCompletionMs = (Sys.time() - started) * 1000.0;
		if (!malformedCompletion.isIncomplete || !hasLabel(malformedCompletion.items, "cursor"))
			throw "small project malformed completion lost current state members";
		started = Sys.time();
		service.update(mainPath, bodySource);
		service.update(pluginPath, plugin);
		var repairedUpdateMs = (Sys.time() - started) * 1000.0;
		service.analyze("workspace.app.Main");
		var repairedPosition = plugin.lastIndexOf("current.cursor") + "current.".length;
		started = Sys.time();
		var repairedCompletion = service.completeResult(pluginPath, repairedPosition);
		var repairedCompletionMs = (Sys.time() - started) * 1000.0;
		if (repairedCompletion.isIncomplete || !hasLabel(repairedCompletion.items, "cursor"))
			throw "small project repair did not restore an exact completion snapshot";
		return {
			updateMs: updateMs,
			completionMs: completionMs,
			definitionMs: definitionMs,
			malformedUpdateMs: malformedUpdateMs,
			malformedCompletionMs: malformedCompletionMs,
			repairedUpdateMs: repairedUpdateMs,
			repairedCompletionMs: repairedCompletionMs,
			modulesInvalidated: bodyAnalysis.invalidatedModules.length,
			modulesAnalyzed: bodyAnalysis.moduleNames.length,
			retypedFunctions: bodyAnalysis.retyped.length,
			recoveredSnapshots: service.recoveredSnapshotBuilds - recoveredBefore
		};
	}

	static function fixtureSourcePaths(root:String):Array<String> {
		var result:Array<String> = [], pending = [root];
		while (pending.length > 0) {
			var directory = pending.pop();
			for (entry in FileSystem.readDirectory(directory)) {
				var path = directory + "/" + entry;
				if (FileSystem.isDirectory(path))
					pending.push(path);
				else if (StringTools.endsWith(entry, ".hx"))
					result.push(path);
			}
		}
		result.sort(Reflect.compare);
		return result;
	}

	static function summarizeScenario(samples:Array<ScenarioSample>):Dynamic {
		return {
			updateMs: percentiles([for (sample in samples) sample.updateMs]),
			completionMs: percentiles([for (sample in samples) sample.completionMs]),
			definitionMs: percentiles([for (sample in samples) sample.definitionMs]),
			malformedUpdateMs: percentiles([for (sample in samples) sample.malformedUpdateMs]),
			malformedCompletionMs: percentiles([for (sample in samples) sample.malformedCompletionMs]),
			repairedUpdateMs: percentiles([for (sample in samples) sample.repairedUpdateMs]),
			repairedCompletionMs: percentiles([for (sample in samples) sample.repairedCompletionMs]),
			modulesInvalidated: percentiles([for (sample in samples) sample.modulesInvalidated]),
			modulesAnalyzed: percentiles([for (sample in samples) sample.modulesAnalyzed]),
			retypedFunctions: percentiles([for (sample in samples) sample.retypedFunctions]),
			recoveredSnapshots: {
				total: sumScenarioSnapshots(samples),
				average: sumScenarioSnapshots(samples) / samples.length
			}
		};
	}

	static function summarizeGenerated(samples:Array<GeneratedSample>):Dynamic {
		return {
			topology: samples[0].topology,
			moduleCount: samples[0].moduleCount,
			updateMs: percentiles([for (sample in samples) sample.updateMs]),
			completionMs: percentiles([for (sample in samples) sample.completionMs]),
			modulesInvalidated: percentiles([for (sample in samples) sample.modulesInvalidated]),
			modulesAnalyzed: percentiles([for (sample in samples) sample.modulesAnalyzed]),
			retypedFunctions: percentiles([for (sample in samples) sample.retypedFunctions]),
			recoveredSnapshots: {
				total: sumGeneratedSnapshots(samples),
				average: sumGeneratedSnapshots(samples) / samples.length
			}
		};
	}

	static function printScenarioSummary(name:String, scenario:Dynamic):Void {
		Sys.println('$name update median/p95/p99: ${format(scenario.updateMs.median)}/${format(scenario.updateMs.p95)}/${format(scenario.updateMs.p99)} ms');
		Sys.println('$name completion median/p95/p99: ${format(scenario.completionMs.median)}/${format(scenario.completionMs.p95)}/${format(scenario.completionMs.p99)} ms');
		Sys.println('$name modules invalidated/analyzed p95: ${format(scenario.modulesInvalidated.p95)}/${format(scenario.modulesAnalyzed.p95)}');
		Sys.println('$name retyped functions p95: ${format(scenario.retypedFunctions.p95)}');
	}

	static function runGeneratedWorkspaceScenario(moduleCount:Int, topology:String):GeneratedSample {
		var service = prepareGeneratedWorkspace(moduleCount, topology),
			recoveredBefore = service.recoveredSnapshotBuilds,
			validSource = generatedSource(moduleCount, topology, 0, false),
			started = Sys.time();
		service.update("generated/Main.hx", validSource);
		var updateMs = (Sys.time() - started) * 1000.0;
		service.compile("generated.Main");
		var target = generatedTarget(moduleCount, topology),
			bodySource = StringTools.replace(validSource, 'return value.known$target;', 'return value.known$target + 0;'),
			bodyStarted = Sys.time();
		service.update("generated/Main.hx", bodySource);
		updateMs += (Sys.time() - bodyStarted) * 1000.0;
		var analysis = service.analyze("generated.Main");
		var malformed = generatedSource(moduleCount, topology, 1, true);
		started = Sys.time();
		service.update("generated/Main.hx", malformed);
		updateMs += (Sys.time() - started) * 1000.0;
		var position = malformed.length,
			queryStarted = Sys.time(),
			completion = service.completeResult("generated/Main.hx", position),
			completionMs = (Sys.time() - queryStarted) * 1000.0;
		if (!completion.isIncomplete || !hasLabel(completion.items, 'known${generatedTarget(moduleCount, topology)}'))
			throw 'generated $topology workspace lost member completion across $moduleCount modules';
		return {
			topology: topology,
			moduleCount: moduleCount,
			updateMs: updateMs,
			completionMs: completionMs,
			modulesInvalidated: analysis.invalidatedModules.length,
			modulesAnalyzed: analysis.moduleNames.length,
			retypedFunctions: analysis.retyped.length,
			recoveredSnapshots: service.recoveredSnapshotBuilds - recoveredBefore
		};
	}

	static function runLongLivedScenario(moduleCount:Int, edits:Int, topology:String):Float {
		var service = prepareGeneratedWorkspace(moduleCount, topology);
		collectGarbage();
		var before = processMemory();
		for (edit in 0...edits) {
			var source = generatedSource(moduleCount, topology, edit, true);
			service.update("generated/Main.hx", source);
			service.completeResult("generated/Main.hx", source.length);
		}
		collectGarbage();
		var after = processMemory();
		return before < 0 || after < 0 ? -1 : after - before;
	}

	static function prepareGeneratedWorkspace(moduleCount:Int, topology:String):LanguageService {
		var service = new LanguageService();
		for (index in 0...moduleCount) {
			var dependencies = generatedDependencies(index, topology),
				importText = [for (dependency in dependencies) 'import generated.Type$dependency;'].join(" "),
				fields = [for (dependency in dependencies) ' public var previous$dependency:Type$dependency;'].join("");
			service.update('generated/Type$index.hx', 'package generated; $importText class Type$index {$fields public var known$index:Int; public function method$index(value:Int):Int return value; }');
		}
		return service;
	}

	static function generatedSource(moduleCount:Int, topology:String, edit:Int, malformed:Bool):String {
		var target = generatedTarget(moduleCount, topology),
			imports:Array<String> = [];
		if (topology == "fanout")
			for (index in 0...moduleCount)
				imports.push('import generated.Type$index;');
		else
			imports.push('import generated.Type$target;');
		var broken = malformed ? ' broken$edit.unresolved().thing;' : "",
			tail = malformed ? 'value.' : 'value.known$target;',
			closing = malformed ? "" : " }";
		return 'package generated; ${imports.join(" ")} function main():Int { var value:Type$target = new Type$target();$broken return $tail$closing';
	}

	static function generatedTarget(moduleCount:Int, topology:String):Int {
		return topology == "chain" ? moduleCount - 1 : topology == "diamond" && moduleCount > 3 ? 3 : 0;
	}

	static function generatedDependencies(index:Int, topology:String):Array<Int> {
		if (index == 0)
			return [];
		return switch (topology) {
			case "chain": [index - 1];
			case "diamond": index == 1 || index == 2 ? [0] : index == 3 ? [1, 2] : [3];
			default: [];
		};
	}

	static function sumScenarioSnapshots(samples:Array<ScenarioSample>):Int {
		var result = 0;
		for (sample in samples)
			result += sample.recoveredSnapshots;
		return result;
	}

	static function sumGeneratedSnapshots(samples:Array<GeneratedSample>):Int {
		var result = 0;
		for (sample in samples)
			result += sample.recoveredSnapshots;
		return result;
	}

	static function collectGarbage():Void {
		#if hl
		hl.Gc.major();
		#end
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
