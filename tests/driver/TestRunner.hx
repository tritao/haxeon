package driver;

import driver.TestCatalog;
import driver.TestCatalog.CompileStep;
import driver.TestCatalog.ExecutableCase;
import driver.TestCatalog.NamedCase;
import driver.TestCatalog.ProgramCase;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

private typedef CommandResult = {
	var status:Int;
	var output:String;
}

private typedef ProgramResult = {
	var index:Int;
	var passed:Bool;
	var output:String;
}

/** A program case built and run once as a live build (a `Compiler`'s default) and once as a plain build, which prunes what nothing reaches. */
private typedef ProgramRun = {
	var test:ProgramCase;
	var plain:Bool;

	/** A plain build without the early prune (`Main --no-early-prune`, `IrEntryPrune`): a migration reference, removed with the switch, so each program runs pruned (the default) and unpruned. */
	var unpruned:Bool;

	/** Built, edited twice and rebuilt in one compiler session (`Main --warm-edit`), each rebuild compared with a fresh build. */
	var warm:Bool;
}

private typedef ActiveProgram = {
	var index:Int;
	var run:ProgramRun;
	var process:Process;
}

/** One command of a test pipeline; `failure` returns a message when the exit status fails the test. */
private typedef PipelineStep = {
	var start:Void->Process;
	var failure:Int->Null<String>;
}

/** Commands that run in order until one fails; `success` is printed when all of them pass. */
private typedef Pipeline = {
	var steps:Array<PipelineStep>;
	var success:String;
}

private typedef ActivePipeline = {
	var index:Int;
	var pipeline:Pipeline;
	var step:Int;
	var process:Process;
	var output:String;
}

class TestRunner {
	final root:String;
	final haxe:String;
	final hl:String;

	/** Compiler entry point prebuilt to HashLink bytecode (HAXEON_MAIN_HL), when scripts/test.sh provides one. */
	final prebuiltMain:Null<String>;

	public function new(root:String) {
		this.root = root;
		var suffix = Sys.systemName() == "Windows" ? ".exe" : "";
		haxe = Path.join([root, ".tools", "haxe", "haxe" + suffix]);
		hl = Path.join([Sys.getEnv("HAXEON_HASHLINK_DIR"), "hl" + suffix]);
		var main = Sys.getEnv("HAXEON_MAIN_HL");
		prebuiltMain = main != null && main != "" && FileSystem.exists(main) ? main : null;
		configureRuntimeLibraryPath();
	}

	/** Compile a program to HashLink: with the prebuilt compiler when available, else `haxe --run Main`. */
	function compileProgram(source:String, output:String, run:ProgramRun):Process {
		var arguments = [source, output].concat((run.warm ? ["--warm-edit"] : run.plain ? ["--plain"] : []).concat(run.unpruned ? ["--no-early-prune"] : []));
		return prebuiltMain != null ? new Process(hl,
			[prebuiltMain].concat(arguments)) : new Process(haxe, ["--cwd", root, "common.hxml", "--run", "Main"].concat(arguments));
	}

	/**
	 * Programs whose warm edit rebuild is known to differ from a fresh build, by name, with the design item that fixes each. A name here
	 * is an expected failure: the case passes while the rebuild still differs in that way, and FAILS once it stops differing, so the
	 * marker cannot outlive its cause. Nothing else is allowed to fail; do not add a name without a note that explains it.
	 */
	static final warmEditKnownFailures:Map<String, String> = [
		"enum-generated-dependencies" => "docs/HELPER_OWNERSHIP.md: a shared helper's origin is chosen by the first requester"
	];

	/** The result for a warm edit build of a program that is marked as a known failure, or null when `run` is not such a build. */
	static function knownWarmFailure(run:ProgramRun, compilation:CommandResult):Null<{passed:Bool, output:String}> {
		var note = run.warm ? warmEditKnownFailures.get(run.test.name) : null;
		if (note == null)
			return null;
		if (compilation.status == 0)
			return {
				passed: false,
				output: compilation.output +
				'FAIL: ${runName(run)} is marked as a known failure ($note) but its warm rebuild now equals a fresh build: remove the marker\n'
			};
		if (compilation.output.indexOf("differs from a fresh build") < 0)
			return {
				passed: false,
				output: compilation.output + 'FAIL: ${runName(run)} is marked as a known failure ($note) but failed in another way\n'
			};
		return {passed: true, output: 'PASS: ${runName(run)} is a known failure, as marked ($note)\n'};
	}

	/**
	 * A program, test main or executable case runs in a directory of its own: a fresh one under out/cases, holding a link to every entry of the repository root
	 * except `out`, which is a new directory linking only the native build (out/cmake and the libraries), so what a program creates there is its own, and removed afterwards. Relative paths such as `out/x` and `tests/fixtures/...`
	 * resolve there, so what a program writes can never collide with another run of it (the live, plain and warm builds run together)
	 * or with another program, and leaves nothing in the tree. The tree itself is reached only through the links.
	 */
	function startProgram(compiled:String, ?arguments:Array<String>):Process {
		var all = [compiled].concat(arguments == null ? [] : arguments);
		if (Sys.systemName() == "Windows")
			return new Process(hl, all);
		return new Process("sh", [
			"-c",
			"r=$1; shift; mkdir -p \"$r/out/cases\" && d=$(mktemp -d \"$r/out/cases/run.XXXXXX\") || exit 125; for e in \"$r\"/* \"$r\"/.[!.]*; do case \"${e##*/}\" in out|.git) continue;; esac; [ -e \"$e\" ] && ln -s \"$e\" \"$d/\"; done; mkdir \"$d/out\"; for e in \"$r\"/out/cmake \"$r\"/out/*.hdll \"$r\"/out/*.so*; do [ -e \"$e\" ] && ln -s \"$e\" \"$d/out/\"; done; (cd \"$d\" && \"$@\"); s=$?; rm -rf \"$d\"; exit $s",
			"sh",
			root,
			hl
		].concat(all));
	}

	/** Programs must not name the shared tree: relative paths resolve in the run's own directory, absolute ones would escape it. */
	function sharedTreeReference(source:String):Bool
		return File.getContent(source).indexOf(root) >= 0;

	static function runName(run:ProgramRun):String
		return run.test.name
			+ (run.warm ? " (warm edit rebuilds" : run.plain ? " (plain build" : "")
			+ (run.unpruned ? ", no early prune" : "")
			+ (run.warm || run.plain ? ")" : "");

	static function runOutput(root:String, run:ProgramRun):String
		return Path.join([
			root,
			"out",
			run.test.name + (run.warm ? ".warm" : run.plain ? ".plain" : "") + (run.unpruned ? ".unpruned" : "") + ".hl"
		]);

	/**
	 * Test mains are compiled to HashLink and run there: faster than re-interpreting the compiler
	 * with `haxe --run` for every main, and it exercises the compiler on the host it ships on.
	 */
	public function runHaxeMains(tests:Array<NamedCase>, jobs:Int):Int
		return runPipelines([
			for (test in tests) {
				var compiled = testMainOutput(test.name);
				{
					steps: [
						compileMainStep(test.name, compiled),
						{
							start: () -> startProgram(compiled),
							failure: status -> status == 0 ? null : 'FAIL: ${test.name} exited with $status'
						}
					],
					success: ""
				};
			}
		], jobs);

	public function runExecutables(tests:Array<ExecutableCase>, jobs:Int):Int
		return runPipelines([for (test in tests) executablePipeline(test)], jobs);

	function executablePipeline(test:ExecutableCase):Pipeline {
		var output = Path.join([root, "out", test.output]),
			setupFailure = (status:Int) -> status == 0 ? null : 'FAIL: ${test.name} setup failed',
			steps:Array<PipelineStep> = switch test.compile {
				// These mains are short compiler-API runners: interpreting them beats compiling each to HashLink.
				case HaxeMain(main, arguments):
					[
						{start: () -> new Process(haxe, haxeMainArguments(main).concat(resolveArguments(output, arguments))), failure: setupFailure}
					];
				case Hxml(path):
					[
						{start: () -> new Process(haxe, ["--cwd", root, Path.join([root, path])]), failure: setupFailure}
					];
			},
			expected = test.expectedExit,
			exitDescription = (status:Int) -> expected == null ? 'non-zero exit $status' : 'exit $expected';
		steps.push({
			start: () -> startProgram(output, resolveArguments(output, test.runtimeArguments)),
			failure: status ->
				(expected == null ? status != 0 : status == expected) ? null : 'FAIL: ${test.name} expected ${exitDescription(status)}, got $status'
		});
		return {steps: steps, success: 'PASS: ${test.message} (${expected == null ? "non-zero exit" : 'exit $expected'})'};
	}

	/** Output path for a compiled test main; one per case, since several cases share a main. */
	function testMainOutput(name:String):String
		return Path.join([root, "out", "test-mains", name + ".hl"]);

	function compileMainStep(main:String, output:String):PipelineStep
		return {
			start: () -> {
				FileSystem.createDirectory(Path.directory(output));
				new Process(haxe, testClassPath().concat(["-hl", output, "-main", main]));
			},
			failure: status -> status == 0 ? null : 'FAIL: $main failed to compile'
		};

	/** Run pipelines on `jobs` workers, reporting each test's output in catalog order. */
	function runPipelines(pipelines:Array<Pipeline>, jobs:Int):Int {
		if (pipelines.length == 0)
			return 0;
		var workerCount = Std.int(Math.max(1, Math.min(jobs, pipelines.length))), results:Array<ProgramResult> = [], active:Array<ActivePipeline> = [],
			next = 0;
		while (next < pipelines.length || active.length > 0) {
			while (next < pipelines.length && active.length < workerCount) {
				var pipeline = pipelines[next];
				active.push({
					index: next,
					pipeline: pipeline,
					step: 0,
					process: pipeline.steps[0].start(),
					output: ""
				});
				next++;
			}
			var current = active.shift(),
				command = finishCommand(current.process),
				failure = current.pipeline.steps[current.step].failure(command.status);
			current.output += command.output;
			if (failure != null)
				results[current.index] = {index: current.index, passed: false, output: current.output + failure + "\n"};
			else if (++current.step < current.pipeline.steps.length) {
				current.process = current.pipeline.steps[current.step].start();
				active.push(current);
			} else {
				var success = current.pipeline.success;
				results[current.index] = {index: current.index, passed: true, output: current.output + (success == "" ? "" : success + "\n")};
			}
		}
		return reportResults(results);
	}

	public function runProgram(test:ProgramCase):Bool {
		var failed = false;
		for (run in runsOf(test)) {
			var result = runProgramCaptured(run, 0);
			Sys.print(result.output);
			failed = failed || !result.passed;
		}
		return !failed;
	}

	/**
	 * The builds of one program: live and plain, and, when HAXEON_CHECK_REUSE=1 asks for the reuse checks, a third that is edited and
	 * rebuilt warm. A cold compile in a fresh process reuses nothing, so only that third build exercises the checks on a program.
	 */
	static function runsOf(test:ProgramCase):Array<ProgramRun> {
		var runs:Array<ProgramRun> = [
			{
				test: test,
				plain: false,
				unpruned: false,
				warm: false
			},
			{
				test: test,
				plain: true,
				unpruned: false,
				warm: false
			},
			{
				test: test,
				plain: true,
				unpruned: true,
				warm: false
			}
		];
		if (Sys.getEnv("HAXEON_CHECK_REUSE") == "1") {
			runs.push({
				test: test,
				plain: true,
				unpruned: false,
				warm: true
			});
			runs.push({
				test: test,
				plain: true,
				unpruned: true,
				warm: true
			});
		}
		return runs;
	}

	/** Every program is built and run three times, live, plain (pruned early, the default) and plain without the early prune, so a difference between the modes fails a case. */
	public function runPrograms(tests:Array<ProgramCase>, jobs:Int):Int {
		if (tests.length == 0)
			return 0;
		var named = [
			for (test in tests)
				if (sharedTreeReference(Path.join([root, "tests", "programs", test.name + ".hx"]))) test.name
		];
		if (named.length > 0) {
			Sys.print([
				for (name in named)
					'FAIL: $name names the shared tree ($root); a program reaches files by relative path, which resolves in its own directory\n'
			].join(""));
			return named.length;
		}
		var runs:Array<ProgramRun> = [for (test in tests) for (run in runsOf(test)) run];
		if (jobs == 1) {
			var failures = 0;
			for (run in runs) {
				var result = runProgramCaptured(run, 0);
				Sys.print(result.output);
				if (!result.passed)
					failures++;
			}
			return failures;
		}
		return reportResults(runProgramsParallel(runs, Std.int(Math.min(jobs, runs.length))));
	}

	function reportResults(results:Array<ProgramResult>):Int {
		var failures = 0;
		for (result in results) {
			Sys.print(result.output);
			if (!result.passed)
				failures++;
		}
		return failures;
	}

	function runProgramsParallel(runs:Array<ProgramRun>, jobs:Int):Array<ProgramResult> {
		var results:Array<ProgramResult> = [];
		var compileOutput:Array<String> = [];
		var compiled = [];
		var next = 0;
		var active:Array<ActiveProgram> = [];
		while (next < runs.length || active.length > 0) {
			while (next < runs.length && active.length < jobs) {
				var run = runs[next];
				var source = Path.join([root, "tests", "programs", run.test.name + ".hx"]);
				active.push({
					index: next,
					run: run,
					process: compileProgram(source, runOutput(root, run), run)
				});
				next++;
			}
			var job = active.shift();
			var compilation = finishCommand(job.process);
			compileOutput[job.index] = compilation.output;
			var known = knownWarmFailure(job.run, compilation);
			if (known != null)
				results[job.index] = {index: job.index, passed: known.passed, output: known.output};
			else if (compilation.status == 0)
				compiled.push(job.index);
			else
				results[job.index] = {
					index: job.index,
					passed: false,
					output: compilation.output + 'FAIL: ${runName(job.run)} failed to compile\n'
				};
		}

		next = 0;
		active = [];
		while (next < compiled.length || active.length > 0) {
			while (next < compiled.length && active.length < jobs) {
				var index = compiled[next++];
				var run = runs[index];
				active.push({index: index, run: run, process: startProgram(runOutput(root, run))});
			}
			var job = active.shift();
			var execution = finishCommand(job.process);
			var expected = job.run.test.expectedExit;
			var passed = execution.status == expected;
			var message = passed ? 'PASS: ${runName(job.run)} source compiled and executed (exit $expected)\n' : 'FAIL: ${runName(job.run)} expected exit $expected, got ${execution.status}\n';
			results[job.index] = {
				index: job.index,
				passed: passed,
				output: compileOutput[job.index] + execution.output + message
			};
		}
		return results;
	}

	function runProgramCaptured(run:ProgramRun, index:Int):ProgramResult {
		var source = Path.join([root, "tests", "programs", run.test.name + ".hx"]);
		var output = runOutput(root, run), test = run.test;
		var compilation = finishCommand(compileProgram(source, output, run));
		var known = knownWarmFailure(run, compilation);
		if (known != null)
			return {index: index, passed: known.passed, output: known.output};
		if (compilation.status != 0) {
			return {
				index: index,
				passed: false,
				output: compilation.output + 'FAIL: ${runName(run)} failed to compile\n'
			};
		}
		var execution = finishCommand(startProgram(output));
		if (execution.status != test.expectedExit) {
			return {
				index: index,
				passed: false,
				output: compilation.output + execution.output + 'FAIL: ${runName(run)} expected exit ${test.expectedExit}, got ${execution.status}\n'
			};
		}
		return {
			index: index,
			passed: true,
			output: compilation.output + execution.output + 'PASS: ${runName(run)} source compiled and executed (exit ${test.expectedExit})\n'
		};
	}

	function runCommand(command:String, arguments:Array<String>):CommandResult {
		return finishCommand(new Process(command, arguments));
	}

	function finishCommand(process:Process):CommandResult {
		var stdout = process.stdout.readAll().toString();
		var stderr = process.stderr.readAll().toString();
		var status = process.exitCode();
		process.close();
		return {status: status, output: stdout + stderr};
	}

	public function runPosInfos():Bool {
		var initialOutput = Path.join([root, "out", "pos-initial.hl"]);
		var editedOutput = Path.join([root, "out", "pos-edited.hl"]);
		var setupStatus = Sys.command(haxe, haxeMainArguments("PosInfosMain").concat([initialOutput, editedOutput]));
		if (setupStatus != 0) {
			Sys.stderr().writeString("FAIL: pos-infos setup failed\n");
			return false;
		}
		for (fixture in [{output: initialOutput, expected: 4}, {output: editedOutput, expected: 5}]) {
			var status = Sys.command(hl, [fixture.output]);
			if (status != fixture.expected) {
				Sys.stderr().writeString('FAIL: pos-infos expected line ${fixture.expected}, got $status\n');
				return false;
			}
		}
		Sys.println("PASS: PosInfos call-site lines refresh after source edits");
		return true;
	}

	function configureRuntimeLibraryPath():Void {
		var paths = ["out", Sys.getEnv("HAXEON_HASHLINK_DIR")]; // "out" is relative so it is the out of the directory a run starts in
		var variable = Sys.systemName() == "Windows" ? "PATH" : (Sys.systemName() == "Mac" ? "DYLD_LIBRARY_PATH" : "LD_LIBRARY_PATH");
		var existing = Sys.getEnv(variable);
		if (existing != null && existing != "")
			paths.push(existing);
		Sys.putEnv(variable, paths.join(Sys.systemName() == "Windows" ? ";" : ":"));
	}

	function haxeMainArguments(main:String):Array<String>
		return testClassPath().concat(["--run", main]);

	function testClassPath():Array<String>
		return [
			"--cwd",
			root,
			"common.hxml",
			"-cp",
			"tests",
			"-cp",
			"tests/compiler",
			"-cp",
			"tests/runtime",
			"-cp",
			"tests/tooling"
		];

	function resolveArguments(output:String, arguments:Array<String>):Array<String> {
		return [
			for (argument in arguments)
				argument.split("{root}").join(root).split("{output}").join(output)
		];
	}
}
