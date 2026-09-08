package driver;

import driver.TestCatalog.CompileStep;
import driver.TestCatalog.ExecutableCase;
import driver.TestCatalog.ProgramCase;
import haxe.io.Path;
import sys.io.Process;
import sys.thread.Deque;
import sys.thread.Thread;

private typedef CommandResult = {
	var status:Int;
	var output:String;
}

private typedef ProgramResult = {
	var index:Int;
	var passed:Bool;
	var output:String;
}

class TestRunner {
	final root:String;
	final haxe:String;
	final hl:String;

	public function new(root:String) {
		this.root = root;
		haxe = Path.join([root, ".tools", "haxe", "haxe"]);
		hl = Path.join([root, "vendor", "hashlink", "hl"]);
		configureRuntimeLibraryPath();
	}

	public function runHaxeMain(name:String):Bool {
		var status = Sys.command(haxe, haxeMainArguments(name));
		if (status == 0)
			return true;
		Sys.stderr().writeString('FAIL: $name exited with $status\n');
		return false;
	}

	public function runExecutable(test:ExecutableCase):Bool {
		var output = Path.join([root, "out", test.output]);
		var setupStatus = switch test.compile {
			case HaxeMain(main, arguments):
				var args = haxeMainArguments(main).concat(resolveArguments(output, arguments));
				Sys.command(haxe, args);
			case Hxml(path):
				Sys.command(haxe, ["--cwd", root, Path.join([root, path])]);
		};
		if (setupStatus != 0) {
			Sys.stderr().writeString('FAIL: ${test.name} setup failed\n');
			return false;
		}
		var status = Sys.command(hl, [output].concat(resolveArguments(output, test.runtimeArguments)));
		var passed = test.expectedExit == null ? status != 0 : status == test.expectedExit;
		if (!passed) {
			var expected = test.expectedExit == null ? "a non-zero exit" : 'exit ${test.expectedExit}';
			Sys.stderr().writeString('FAIL: ${test.name} expected $expected, got $status\n');
			return false;
		}
		var exitDescription = test.expectedExit == null ? 'non-zero exit $status' : 'exit ${test.expectedExit}';
		Sys.println('PASS: ${test.message} ($exitDescription)');
		return true;
	}

	public function runProgram(test:ProgramCase):Bool {
		var result = runProgramCaptured(test, 0);
		Sys.print(result.output);
		return result.passed;
	}

	public function runPrograms(tests:Array<ProgramCase>, jobs:Int):Int {
		if (tests.length == 0)
			return 0;
		if (jobs == 1) {
			var failures = 0;
			for (test in tests)
				if (!runProgram(test))
					failures++;
			return failures;
		}

		var workerCount = Std.int(Math.min(jobs, tests.length));
		var completed = new Deque<ProgramResult>();
		for (workerIndex in 0...workerCount)
			startProgramWorker(tests, workerIndex, workerCount, completed);

		var ordered:Array<ProgramResult> = [];
		for (_ in 0...tests.length) {
			var result = completed.pop(true);
			ordered[result.index] = result;
		}
		var failures = 0;
		for (result in ordered) {
			Sys.print(result.output);
			if (!result.passed)
				failures++;
		}
		return failures;
	}

	function startProgramWorker(tests:Array<ProgramCase>, offset:Int, stride:Int, completed:Deque<ProgramResult>):Void {
		Thread.create(() -> {
			var index = offset;
			while (index < tests.length) {
				try
					completed.add(runProgramCaptured(tests[index], index))
				catch (error:Dynamic)
					completed.add({index: index, passed: false, output: 'FAIL: ${tests[index].name}: ${Std.string(error)}\n'});
				index += stride;
			}
		});
	}

	function runProgramCaptured(test:ProgramCase, index:Int):ProgramResult {
		var source = Path.join([root, "tests", "programs", test.name + ".hx"]);
		var output = Path.join([root, "out", test.name + ".hl"]);
		var compilation = runCommand(haxe, ["--cwd", root, "-cp", "src", "--run", "Main", source, output]);
		if (compilation.status != 0) {
			return {
				index: index,
				passed: false,
				output: compilation.output + 'FAIL: ${test.name} failed to compile\n'
			};
		}
		var execution = runCommand(hl, [output]);
		if (execution.status != test.expectedExit) {
			return {
				index: index,
				passed: false,
				output: compilation.output + execution.output + 'FAIL: ${test.name} expected exit ${test.expectedExit}, got ${execution.status}\n'
			};
		}
		return {
			index: index,
			passed: true,
			output: compilation.output + execution.output + 'PASS: ${test.name} source compiled and executed (exit ${test.expectedExit})\n'
		};
	}

	function runCommand(command:String, arguments:Array<String>):CommandResult {
		var process = new Process(command, arguments);
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
		var paths = [Path.join([root, "out"]), Path.join([root, "vendor", "hashlink"])];
		var existing = Sys.getEnv("LD_LIBRARY_PATH");
		if (existing != null && existing != "")
			paths.push(existing);
		Sys.putEnv("LD_LIBRARY_PATH", paths.join(":"));
	}

	function haxeMainArguments(main:String):Array<String> {
		return [
			"--cwd",
			root,
			"-cp",
			"src",
			"-cp",
			"tests",
			"-cp",
			"tests/compiler",
			"-cp",
			"tests/runtime",
			"-cp",
			"tests/tooling",
			"--run",
			main
		];
	}

	function resolveArguments(output:String, arguments:Array<String>):Array<String> {
		return [
			for (argument in arguments)
				argument.split("{root}").join(root).split("{output}").join(output)
		];
	}
}
