package driver;

import driver.TestCatalog;
import driver.TestCatalog.CompileStep;
import driver.TestCatalog.ExecutableCase;
import driver.TestCatalog.NamedCase;
import driver.TestCatalog.ProgramCase;
import haxe.io.Path;
import sys.FileSystem;
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
	function compileProgram(source:String, output:String, plain:Bool):Process {
		var arguments = [source, output].concat(plain ? ["--plain"] : []);
		return prebuiltMain != null ? new Process(hl,
			[prebuiltMain].concat(arguments)) : new Process(haxe, ["--cwd", root, "common.hxml", "--run", "Main"].concat(arguments));
	}

	static function runName(run:ProgramRun):String
		return run.test.name + (run.plain ? " (plain build)" : "");

	static function runOutput(root:String, run:ProgramRun):String
		return Path.join([root, "out", run.test.name + (run.plain ? ".plain" : "") + ".hl"]);

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
							start: () -> new Process(hl, [compiled]),
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
			start: () -> new Process(hl, [output].concat(resolveArguments(output, test.runtimeArguments))),
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
		for (plain in [false, true]) {
			var result = runProgramCaptured({test: test, plain: plain}, 0);
			Sys.print(result.output);
			failed = failed || !result.passed;
		}
		return !failed;
	}

	/** Every program is built and run twice, live and plain, so a difference between the two modes (what a plain build prunes) fails a case. */
	public function runPrograms(tests:Array<ProgramCase>, jobs:Int):Int {
		if (tests.length == 0)
			return 0;
		var runs:Array<ProgramRun> = [for (test in tests) for (plain in [false, true]) {test: test, plain: plain}];
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
					process: compileProgram(source, runOutput(root, run), run.plain)
				});
				next++;
			}
			var job = active.shift();
			var compilation = finishCommand(job.process);
			compileOutput[job.index] = compilation.output;
			if (compilation.status == 0)
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
				active.push({index: index, run: run, process: new Process(hl, [runOutput(root, run)])});
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
		var compilation = finishCommand(compileProgram(source, output, run.plain));
		if (compilation.status != 0) {
			return {
				index: index,
				passed: false,
				output: compilation.output + 'FAIL: ${runName(run)} failed to compile\n'
			};
		}
		var execution = runCommand(hl, [output]);
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
		var paths = [Path.join([root, "out"]), Sys.getEnv("HAXEON_HASHLINK_DIR")];
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
