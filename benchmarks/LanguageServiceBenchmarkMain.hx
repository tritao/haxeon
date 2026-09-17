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
	final signatureModulesInvalidated:Int;
	final modulesAnalyzed:Int;
	final reusedClasses:Int;
	final retypedFunctions:Int;
	final recoveredSnapshots:Int;
	final editMatrix:Array<GeneratedEditMeasurement>;
}

private typedef GeneratedEditMeasurement = {
	final kind:String;
	final updateMs:Float;
	final followupMs:Float;
	final modulesInvalidated:Int;
	final modulesAnalyzed:Int;
	final reusedClasses:Int;
	final retypedFunctions:Int;
	final recoveredSnapshots:Int;
}

private typedef GeneratedEditInput = {
	final path:String;
	final source:String;
	final expectedInvalidated:Array<String>;
}

private enum GeneratedEditKind {
	BodyOnly;
	PublicSignature;
	FieldType;
	ImportChange;
	BaseClassChange;
	InterfaceChange;
	AddDeclaration;
	RemoveDeclaration;
}

private typedef GeneratedScenarioSpec = {
	final name:String;
	final topology:String;
	final moduleCount:Int;
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
			scaleModulesOverride = stringArg(args, "--scale-modules", null),
			scaleSizes = scaleModulesOverride == null
				? intListArg(args, "--scale-sizes", [8, 64])
				: [parsePositiveInt(scaleModulesOverride, "--scale-modules")],
			scaleTopologyOverride = stringArg(args, "--scale-topology", null),
			scaleTopologies = stringListArg(args, "--scale-topologies",
				scaleTopologyOverride == null ? ["fanout", "chain", "diamond"] : [scaleTopologyOverride]),
			enduranceTopology = stringArg(args, "--endurance-topology", scaleTopologies[0]),
			enduranceModules = intArg(args, "--endurance-modules", scaleSizes[scaleSizes.length - 1]),
			enduranceEdits = intArg(args, "--endurance-edits", 250),
			output = stringArg(args, "--json", "out/editor-benchmark.json"),
			checkBudgets = hasFlag(args, "--check-budgets");
		if (iterations < 1 || warmup < 0 || scenarioIterations < 1 || scaleIterations < 1 || scaleSizes.length == 0 || enduranceModules < 1 || enduranceEdits < 1)
			throw "iterations and scale parameters must be positive; warmup cannot be negative";
		for (topology in scaleTopologies)
			validateTopology(topology);
		validateTopology(enduranceTopology);

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
			generatedScenarios = generatedScenarioSpecs(scaleSizes, scaleTopologies),
			generatedReports:Dynamic = {};
		for (scenario in generatedScenarios) {
			var generatedSamples = [for (_ in 0...scaleIterations) runGeneratedWorkspaceScenario(scenario)];
			Reflect.setField(generatedReports, scenario.name, summarizeGenerated(generatedSamples));
		}
		var longLivedMemoryGrowth = runLongLivedScenario(enduranceModules, enduranceEdits, enduranceTopology),
			scenarios:Dynamic = {};
		Reflect.setField(scenarios, "small-project", summarizeScenario(scenarioSamples));
		for (scenario in generatedScenarios)
			Reflect.setField(scenarios, scenario.name, Reflect.field(generatedReports, scenario.name));
		var report = {
			version: 7,
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
			// Keep the legacy field useful for consumers that only display one
			// scale, while scaleSizes is the authoritative matrix configuration.
			scaleModules: scaleSizes[scaleSizes.length - 1],
			scaleSizes: scaleSizes,
			scaleTopology: scaleTopologies.length == 1 ? scaleTopologies[0] : "matrix",
			scaleTopologies: scaleTopologies,
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
		for (scenario in generatedScenarios)
			printScenarioSummary(scenario.name, Reflect.field(scenarios, scenario.name));
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
			if (Reflect.hasField(scenario, "editMatrix"))
				for (editName in Reflect.fields(scenario.editMatrix)) {
					var edit:Dynamic = Reflect.field(scenario.editMatrix, editName);
					checkBudget('$name $editName edit', edit.updateMs.p95, limit);
					checkBudget('$name $editName follow-up', edit.followupMs.p95, limit);
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
			signatureModulesInvalidated: percentiles([for (sample in samples) sample.signatureModulesInvalidated]),
			modulesAnalyzed: percentiles([for (sample in samples) sample.modulesAnalyzed]),
			reusedClasses: percentiles([for (sample in samples) sample.reusedClasses]),
			retypedFunctions: percentiles([for (sample in samples) sample.retypedFunctions]),
			editMatrix: summarizeGeneratedEdits(samples),
			recoveredSnapshots: {
				total: sumGeneratedSnapshots(samples),
				average: sumGeneratedSnapshots(samples) / samples.length
			}
		};
	}

	static function summarizeGeneratedEdits(samples:Array<GeneratedSample>):Dynamic {
		var result:Dynamic = {};
		for (measurement in samples[0].editMatrix) {
			var selected:Array<GeneratedEditMeasurement> = [];
			for (sample in samples)
				for (candidate in sample.editMatrix)
					if (candidate.kind == measurement.kind)
						selected.push(candidate);
			Reflect.setField(result, measurement.kind, {
				updateMs: percentiles([for (sample in selected) sample.updateMs]),
				followupMs: percentiles([for (sample in selected) sample.followupMs]),
				modulesInvalidated: percentiles([for (sample in selected) sample.modulesInvalidated]),
				modulesAnalyzed: percentiles([for (sample in selected) sample.modulesAnalyzed]),
				reusedClasses: percentiles([for (sample in selected) sample.reusedClasses]),
				retypedFunctions: percentiles([for (sample in selected) sample.retypedFunctions]),
				recoveredSnapshots: {
					total: sumEditSnapshots(selected),
					average: sumEditSnapshots(selected) / selected.length
				}
			});
		}
		return result;
	}

	static function printScenarioSummary(name:String, scenario:Dynamic):Void {
		Sys.println('$name update median/p95/p99: ${format(scenario.updateMs.median)}/${format(scenario.updateMs.p95)}/${format(scenario.updateMs.p99)} ms');
		Sys.println('$name completion median/p95/p99: ${format(scenario.completionMs.median)}/${format(scenario.completionMs.p95)}/${format(scenario.completionMs.p99)} ms');
		Sys.println('$name modules invalidated/analyzed p95: ${format(scenario.modulesInvalidated.p95)}/${format(scenario.modulesAnalyzed.p95)}');
		if (Reflect.hasField(scenario, "reusedClasses"))
			Sys.println('$name reused classes p95: ${format(scenario.reusedClasses.p95)}');
		if (Reflect.hasField(scenario, "signatureModulesInvalidated"))
			Sys.println('$name signature modules invalidated p95: ${format(scenario.signatureModulesInvalidated.p95)}');
		Sys.println('$name retyped functions p95: ${format(scenario.retypedFunctions.p95)}');
		if (Reflect.hasField(scenario, "editMatrix"))
			for (editName in Reflect.fields(scenario.editMatrix)) {
				var edit:Dynamic = Reflect.field(scenario.editMatrix, editName);
				Sys.println('$name $editName invalidated/analyzed/reused p95: ${format(edit.modulesInvalidated.p95)}/${format(edit.modulesAnalyzed.p95)}/${format(edit.reusedClasses.p95)}');
			}
	}

	static function generatedScenarioSpecs(scaleSizes:Array<Int>, topologies:Array<String>):Array<GeneratedScenarioSpec> {
		var result:Array<GeneratedScenarioSpec> = [];
		for (topology in topologies)
			for (moduleCount in scaleSizes)
				result.push({
					name: 'generated-$moduleCount-$topology',
					topology: topology,
					moduleCount: moduleCount
				});
		return result;
	}

	static function runGeneratedWorkspaceScenario(scenario:GeneratedScenarioSpec):GeneratedSample {
		var moduleCount = scenario.moduleCount,
			topology = scenario.topology,
			service = prepareGeneratedWorkspace(moduleCount, topology),
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
		assertInvalidatedModules(analysis.invalidatedModules, ["generated.Main"], '${scenario.name} body edit');
		var expectedReusedClasses = generatedReachableTypeCount(moduleCount, topology);
		if (analysis.reusedClasses != expectedReusedClasses)
			throw '${scenario.name} body edit reused ${analysis.reusedClasses} classes, expected $expectedReusedClasses';
		var signaturePath = "generated/Type0.hx",
			signatureStarted = Sys.time();
		service.update(signaturePath, generatedTypeSource(0, topology, PublicSignature));
		updateMs += (Sys.time() - signatureStarted) * 1000.0;
		var signatureAnalysis = service.analyze("generated.Main");
		assertInvalidatedModules(signatureAnalysis.invalidatedModules, expectedSignatureInvalidations(moduleCount, topology), '${scenario.name} signature edit');
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
		var editMatrix = runGeneratedEditMatrix(moduleCount, topology);
		return {
			topology: topology,
			moduleCount: moduleCount,
			updateMs: updateMs,
			completionMs: completionMs,
			modulesInvalidated: analysis.invalidatedModules.length,
			signatureModulesInvalidated: signatureAnalysis.invalidatedModules.length,
			modulesAnalyzed: analysis.moduleNames.length,
			reusedClasses: analysis.reusedClasses,
			retypedFunctions: analysis.retyped.length,
			recoveredSnapshots: service.recoveredSnapshotBuilds - recoveredBefore,
			editMatrix: editMatrix
		};
	}

	static function runGeneratedEditMatrix(moduleCount:Int, topology:String):Array<GeneratedEditMeasurement> {
		var service = prepareGeneratedWorkspace(moduleCount, topology),
			validSource = generatedSource(moduleCount, topology, 0, false),
			mainPath = "generated/Main.hx";
		service.update(mainPath, validSource);
		service.compile("generated.Main");
		var measurements:Array<GeneratedEditMeasurement> = [];
		for (kind in generatedEditKinds()) {
			resetGeneratedEditorState(service, moduleCount, topology, validSource);
			measurements.push(measureGeneratedEdit(service, moduleCount, topology, kind, validSource));
		}

		resetGeneratedEditorState(service, moduleCount, topology, validSource);
		var recoveredBefore = service.recoveredSnapshotBuilds,
			malformed = generatedSource(moduleCount, topology, 2, true),
			started = Sys.time();
		service.update(mainPath, malformed);
		var updateMs = (Sys.time() - started) * 1000.0,
			position = malformed.length,
			queryStarted = Sys.time(),
			completion = service.completeResult(mainPath, position),
			analysisMs = (Sys.time() - queryStarted) * 1000.0;
		if (!completion.isIncomplete || !hasLabel(completion.items, 'known${generatedTarget(moduleCount, topology)}'))
			throw 'generated $topology malformed edit lost member completion across $moduleCount modules';
		measurements.push({
			kind: "malformed-intermediate",
			updateMs: updateMs,
			followupMs: analysisMs,
			modulesInvalidated: 0,
			modulesAnalyzed: 0,
			reusedClasses: 0,
			retypedFunctions: 0,
			recoveredSnapshots: service.recoveredSnapshotBuilds - recoveredBefore
		});

		started = Sys.time();
		service.update(mainPath, validSource);
		updateMs = (Sys.time() - started) * 1000.0;
		queryStarted = Sys.time();
		var repaired = service.analyze("generated.Main");
		analysisMs = (Sys.time() - queryStarted) * 1000.0;
		assertInvalidatedModules(repaired.invalidatedModules, ["generated.Main"], 'generated-$moduleCount-$topology repair');
		measurements.push({
			kind: "repair",
			updateMs: updateMs,
			followupMs: analysisMs,
			modulesInvalidated: repaired.invalidatedModules.length,
			modulesAnalyzed: repaired.moduleNames.length,
			reusedClasses: repaired.reusedClasses,
			retypedFunctions: repaired.retyped.length,
			recoveredSnapshots: service.recoveredSnapshotBuilds - recoveredBefore
		});
		return measurements;
	}

	static function generatedEditKinds():Array<GeneratedEditKind> {
		return [BodyOnly, PublicSignature, FieldType, ImportChange, BaseClassChange, InterfaceChange, AddDeclaration, RemoveDeclaration];
	}

	static function resetGeneratedEditorState(service:LanguageService, moduleCount:Int, topology:String, validSource:String):Void {
		service.update("generated/Type0.hx", generatedTypeSource(0, topology));
		if (moduleCount > 1)
			service.update("generated/Type1.hx", generatedTypeSource(1, topology));
		service.update("generated/Main.hx", validSource);
		service.analyze("generated.Main");
	}

	static function measureGeneratedEdit(service:LanguageService, moduleCount:Int, topology:String, kind:GeneratedEditKind,
		validSource:String):GeneratedEditMeasurement {
		var input = generatedEditInput(moduleCount, topology, kind, validSource),
			recoveredBefore = service.recoveredSnapshotBuilds,
			started = Sys.time();
		service.update(input.path, input.source);
		var updateMs = (Sys.time() - started) * 1000.0,
			analysisStarted = Sys.time(),
			analysis = service.analyze("generated.Main"),
			analysisMs = (Sys.time() - analysisStarted) * 1000.0;
		assertInvalidatedModules(analysis.invalidatedModules, input.expectedInvalidated, 'generated-$moduleCount-$topology ${generatedEditName(kind)}');
		return {
			kind: generatedEditName(kind),
			updateMs: updateMs,
			followupMs: analysisMs,
			modulesInvalidated: analysis.invalidatedModules.length,
			modulesAnalyzed: analysis.moduleNames.length,
			reusedClasses: analysis.reusedClasses,
			retypedFunctions: analysis.retyped.length,
			recoveredSnapshots: service.recoveredSnapshotBuilds - recoveredBefore
		};
	}

	static function generatedEditInput(moduleCount:Int, topology:String, kind:GeneratedEditKind, validSource:String):GeneratedEditInput {
		var typeIndex = kind == FieldType && moduleCount > 1 ? 1 : 0,
			path = kind == BodyOnly ? "generated/Main.hx" : 'generated/Type$typeIndex.hx',
			source = kind == BodyOnly ? StringTools.replace(validSource, 'return value.known${generatedTarget(moduleCount, topology)};', 'return value.known${generatedTarget(moduleCount, topology)} + 0;') : generatedTypeSource(typeIndex, topology, kind);
		return {
			path: path,
			source: source,
			expectedInvalidated: expectedEditInvalidations(kind, typeIndex, moduleCount, topology)
		};
	}

	static function expectedEditInvalidations(kind:GeneratedEditKind, typeIndex:Int, moduleCount:Int, topology:String):Array<String> {
		return switch (kind) {
			case BodyOnly: ["generated.Main"];
			case ImportChange: ["generated.Base", 'generated.Type$typeIndex'];
			case InterfaceChange: ["generated.Contract", 'generated.Type$typeIndex'];
			default: expectedTypeInvalidations(typeIndex, moduleCount, topology);
		};
	}

	static function generatedEditName(kind:GeneratedEditKind):String {
		return switch (kind) {
			case BodyOnly: "body-only";
			case PublicSignature: "public-signature";
			case FieldType: "field-type";
			case ImportChange: "import-change";
			case BaseClassChange: "base-class-change";
			case InterfaceChange: "interface-change";
			case AddDeclaration: "add-declaration";
			case RemoveDeclaration: "remove-declaration";
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
		service.update("generated/Base.hx", "package generated; class Base {} ");
		service.update("generated/Contract.hx", "package generated; interface Contract {} ");
		for (index in 0...moduleCount)
			service.update('generated/Type$index.hx', generatedTypeSource(index, topology));
		return service;
	}

	static function generatedTypeSource(index:Int, topology:String, ?edit:GeneratedEditKind):String {
		var dependencies = generatedDependencies(index, topology),
			imports = [for (dependency in dependencies) 'import generated.Type$dependency;'],
			fields = [for (dependency in dependencies) ' public var previous$dependency:Type$dependency;'].join(""),
			methodReturn = edit == PublicSignature ? "String" : "Int",
			methodBody = edit == PublicSignature ? '"changed"' : "value",
			knownType = "Int",
			typedType = edit == FieldType ? "String" : "Int",
			inheritance = "",
			declarations = ' public var known$index:$knownType; public var typed$index:$typedType;',
			method = ' public function method$index(value:Int):$methodReturn return $methodBody;';
		switch (edit) {
			case ImportChange:
				imports.push("import generated.Base;");
			case BaseClassChange:
				imports.push("import generated.Base;");
				inheritance = " extends Base";
			case InterfaceChange:
				imports.push("import generated.Contract;");
				inheritance = " implements Contract";
			case AddDeclaration:
				declarations += ' public var added$index:Int;';
			case RemoveDeclaration:
				method = "";
			default:
		}
		var importText = imports.join(" ");
		return 'package generated; $importText class Type$index$inheritance {$fields$declarations$method }';
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

	static function assertInvalidatedModules(actual:Array<String>, expected:Array<String>, label:String):Void {
		var actualSorted = actual.copy(),
			expectedSorted = expected.copy();
		actualSorted.sort(Reflect.compare);
		expectedSorted.sort(Reflect.compare);
		if (actualSorted.join("\n") != expectedSorted.join("\n"))
			throw '$label invalidated ${actualSorted.join(", ")}, expected ${expectedSorted.join(", ")}';
	}

	static function expectedSignatureInvalidations(moduleCount:Int, topology:String):Array<String> {
		return expectedTypeInvalidations(0, moduleCount, topology);
	}

	static function expectedTypeInvalidations(typeIndex:Int, moduleCount:Int, topology:String):Array<String> {
		var result = ['generated.Type$typeIndex'];
		for (index in 0...moduleCount)
			if (generatedDependencies(index, topology).contains(typeIndex))
				result.push('generated.Type$index');
		if (topology == "fanout" && typeIndex == generatedTarget(moduleCount, topology))
			result.push("generated.Main");
		return result;
	}

	static function generatedReachableTypeCount(moduleCount:Int, topology:String):Int {
		return topology == "diamond" && moduleCount > 3 ? 4 : moduleCount;
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

	static function sumEditSnapshots(samples:Array<GeneratedEditMeasurement>):Int {
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

	static function intListArg(args:Array<String>, name:String, fallback:Array<Int>):Array<Int> {
		var value = stringArg(args, name, null);
		if (value == null)
			return fallback;

		var result:Array<Int> = [];
		for (part in value.split(","))
			result.push(parsePositiveInt(StringTools.trim(part), name));
		return result;
	}

	static function stringListArg(args:Array<String>, name:String, fallback:Array<String>):Array<String> {
		var value = stringArg(args, name, null);
		if (value == null)
			return fallback;

		var result:Array<String> = [];
		for (part in value.split(",")) {
			var item = StringTools.trim(part);
			if (item.length == 0)
				throw '$name values cannot be empty';
			result.push(item);
		}
		return result;
	}

	static function validateTopology(topology:String):Void {
		if (topology != "fanout" && topology != "chain" && topology != "diamond")
			throw 'unsupported generated workspace topology "$topology"';
	}

	static function parsePositiveInt(value:String, name:String):Int {
		var parsed = Std.parseInt(value);
		if (parsed == null || parsed < 1)
			throw '$name values must be positive integers';
		return parsed;
	}

	static function hasFlag(args:Array<String>, name:String):Bool {
		for (argument in args)
			if (argument == name)
				return true;
		return false;
	}
}
