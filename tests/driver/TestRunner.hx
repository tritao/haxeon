package driver;

import driver.CompileWorkers.CompileWorker;
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

	/** A plain build without the early prune (`--no-early-prune`, `IrEntryPrune`): a migration reference, removed with the switch, so each program runs pruned (the default) and unpruned. */
	var unpruned:Bool;

	/** Built, edited three times and rebuilt in one compile server session, each rebuild compared with a fresh build (`warmEdit`). */
	var warm:Bool;
}

private typedef ActiveProgram = {
	var index:Int;
	var run:ProgramRun;
	var command:RunningCommand;
}

/** A command in flight, its output drained as it runs: `finish` waits for it and returns its status and output. */
private typedef RunningCommand = {
	var finish:Void->CommandResult;
}

private typedef ActiveCompile = {
	var index:Int;
	var run:ProgramRun;
	var compile:RunningCommand;
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
	var command:RunningCommand;
	var output:String;
}

class TestRunner {
	final root:String;
	final haxe:String;
	final hl:String;

	/** `--check-reuse`: programs are also rebuilt warm, and every compile checks what it reuses (`CompileOptions.checkReuse`). */
	public var checkReuse = false;


	/**
	 * `--check-isolation`: each program is also compiled in a compile server started for it alone, and must come out byte for byte as
	 * it does in the shared server, after whatever that server compiled before. A difference is state one compile left in the process
	 * for the next (see CompilerStaticsMain).
	 */
	public var checkIsolation = false;

	/** `--release`: the plain builds are release builds (`--build-mode=release`), whose code generation differs from development's. */
	public var release = false;

	/**
	 * The command that starts a compile server (the rendezvous path is appended): the server prebuilt to HashLink bytecode
	 * (`HAXEON_COMPILER_SERVER_HL`, which `haxeon dev test-driver` provides), else `haxe --run compiler.tools.CompilerServer`.
	 */
	final serverCommand:Array<String>;

	public function new(root:String) {
		this.root = root;
		var suffix = Sys.systemName() == "Windows" ? ".exe" : "";
		haxe = Path.join([root, ".tools", "haxe", "haxe" + suffix]);
		hl = Path.join([Sys.getEnv("HAXEON_SDK"), "bin", "hl" + suffix]);
		var server = Sys.getEnv("HAXEON_COMPILER_SERVER_HL");
		serverCommand = server != null && server != "" && FileSystem.exists(server) ? [hl, server] : [
			haxe,
			"--cwd",
			root,
			"common.hxml",
			"--run",
			"compiler.tools.CompilerServer"
		];
		knownElaborationDifferences = readKnownDifferences(Path.join([
			root,
			"tests",
			"driver",
			"elaboration-known-differences.txt"
		]));
		configureRuntimeLibraryPath();
	}

	/** The compile servers the programs compile in, while `runPrograms` runs. */
	var workers:Null<CompileWorkers> = null;

	function compileWorkers():CompileWorkers {
		var current = workers;
		if (current == null) {
			var temp = Sys.getEnv("TMPDIR");
			if (temp == null || temp == "")
				temp = Sys.systemName() == "Windows" ? Sys.getEnv("TEMP") : "/tmp";
			current = new CompileWorkers(serverCommand, Path.join([
				temp,
				'haxeon-compile-workers-${Std.random(0x3fffffff)}'
			]));
			workers = current;
		}
		return current;
	}

	function closeCompileWorkers():Void {
		var current = workers;
		if (current != null)
			current.close();
		workers = null;
	}

	/** The compile request for `source`, built into `output`: a live build unless `plain`, with the run's options. */
	function programRequest(source:String, output:String, run:ProgramRun, roots:Array<String>):Array<String> {
		var arguments = [
			"--target=hl",
			"--entry=" + Path.withoutExtension(Path.withoutDirectory(source)),
			"--output=" + output
		];
		for (root in roots)
			arguments.push("--root=" + root);
		if (!run.plain) {
			arguments.push("--live");
			// A live build keeps every function, `Reflect`'s among them, so it reflects over every layout and boxes what a plain
			// build keeps inline: a program's allocation census holds only in a plain build, which `live_build` tells it.
			arguments.push("--define=live_build");
		} else {
			if (release) {
				arguments.push("--build-mode=release");
				arguments.push("--verify-ir");
			}
		}
		if (run.unpruned)
			arguments.push("--no-early-prune");
		if (checkReuse)
			arguments.push("--check-reuse");
		arguments.push(source);
		return arguments;
	}

	/** Compiles a program to HashLink in a compile server, in a fresh session; a warm run builds and rebuilds it in one. */
	function compileProgram(source:String, output:String, run:ProgramRun):RunningCommand {
		if (run.warm)
			return {finish: () -> warmEdit(source, output, run)};
		var roots = [Path.directory(source)],
			pending = compileWorkers().start(programRequest(source, output, run, roots).concat(["--session=fresh"]));
		// One build per program is checked, the live one, which keeps the most of a compile's state.
		if (!checkIsolation || run.plain)
			return {finish: () -> pending.finish()};
		var alone = output + ".isolated",
			isolated = compileWorkers().isolated(programRequest(source, alone, run, roots).concat(["--session=fresh"]));
		return {finish: () -> {
			var shared = pending.finish(), own = isolated.finish();
			var result = shared;
			if (shared.status == 0 && own.status != 0)
				result = {
					status: 1,
					output: shared.output + own.output
						+ '$source compiled in the shared compile server but not in one of its own\n'
				};
			else if (shared.status == 0
				&& (!FileSystem.exists(alone) || File.getBytes(output).compare(File.getBytes(alone)) != 0))
				result = {
					status: 1,
					output: shared.output
						+ '$source compiles differently in a compile server that compiled other programs before it than in one of its own: '
						+ 'an earlier compile left state in the process\n'
				};
			for (name in FileSystem.readDirectory(Path.directory(alone)))
				if (StringTools.startsWith(name, Path.withoutDirectory(alone)))
					FileSystem.deleteFile(Path.join([Path.directory(alone), name]));
			return result;
		}
		};
	}

	/**
	 * Warm-rebuild coverage for a program: build it, add a function nothing reaches and rebuild in the same session, add a kept function
	 * (so the module changes) and rebuild, then put both inside the file and rebuild again. Each rebuild must be the bytes of a fresh
	 * session's build of the same text; with `--check-reuse` the compiler also compares what it reused with what it would have built.
	 * Last, the original is built with its bodies typed in reverse order (`--reverse-typing-order`), which must not change a byte.
	 * The edits are made to a copy of the program, so the other builds of it never see them; the program's own directory stays a root.
	 */
	function warmEdit(source:String, output:String, run:ProgramRun):CommandResult {
		var original = File.getContent(source),
			name = Path.withoutDirectory(source),
			temp = Sys.getEnv("TMPDIR");
		if (temp == null || temp == "")
			temp = Sys.systemName() == "Windows" ? Sys.getEnv("TEMP") : "/tmp";
		var directory = Path.join([temp, 'haxeon-warm-edit-${Std.random(0x3fffffff)}']);
		FileSystem.createDirectory(directory);
		var copy = Path.join([directory, name]),
			roots = [directory, Path.directory(source)];
		var unused = "\nfunction __warmEditUnused():Int return 1;\n";
		// The third edit lands inside the file, after the last top-level closing brace before the middle of the file, so the declarations
		// before it keep their ranges and the ones after it move: both kinds of function must come out as a fresh build has them.
		var kept = "@:keep function __warmEditKept():Int return 424242;\n",
			cut = original.lastIndexOf("\n}\n", Std.int(original.length / 2));
		var inside = cut < 0 ? original + unused + kept : original.substr(0,
			cut + 3) + unused + kept + original.substr(cut + 3);
		var edits = [original + unused, original + unused + kept, inside],
			labels = ["a function nothing reaches, appended", "a kept function, appended", "functions inside the file"];
		function build(worker:CompileWorker, text:String, into:String, session:String,
				?flags:Array<String>):CommandResult {
			File.saveContent(copy, text);
			return worker.compile(programRequest(copy, into, run, roots).concat(["--session=" + session])
				.concat(flags == null ? [] : flags));
		}
		var log = new StringBuf();
		var result = compileWorkers().with(worker -> {
			var first = build(worker, original, Path.join([directory, "warm-0.hl"]), "fresh");
			log.add(first.output);
			if (first.status != 0)
				return first;
			for (index in 0...edits.length) {
				var warm = build(worker, edits[index], Path.join([directory, 'warm-${index + 1}.hl']), "reuse");
				log.add(warm.output);
				if (warm.status != 0)
					return warm;
			}
			// The fresh builds come last: each starts the session over.
			for (index in 0...edits.length) {
				var fresh = build(worker, edits[index], Path.join([directory, 'fresh-${index + 1}.hl']), "fresh");
				log.add(fresh.output);
				if (fresh.status != 0)
					return fresh;
				var warmBytes = File.getBytes(Path.join([directory, 'warm-${index + 1}.hl'])),
					freshBytes = File.getBytes(Path.join([directory, 'fresh-${index + 1}.hl']));
				if (warmBytes.compare(freshBytes) != 0)
					return {
						status: 1,
						output: 'a warm rebuild of $source differs from a fresh build of the same text (edit ${index + 1}: ${labels[index]})\n'
					};
			}
			// Typing a body depends only on the program and the body: typing them in reverse order must give the same bytes.
			var reversed = build(worker, original, Path.join([directory, "reversed-0.hl"]), "fresh",
				["--reverse-typing-order"]);
			log.add(reversed.output);
			if (reversed.status != 0)
				return reversed;
			if (File.getBytes(Path.join([directory, "warm-0.hl"]))
				.compare(File.getBytes(Path.join([directory, "reversed-0.hl"]))) != 0)
				return {
					status: 1,
					output: 'a build of $source that types its bodies in reverse order (--reverse-typing-order) differs from one in declaration order\n'
				};
			// A generic class's erased code made from its own-parameter typing by the elaboration pass must be the code typing it again
			// with its parameters erased gives (docs/design/GENERIC_TYPING_ONCE.md, stage 2).
			var elaborated = build(worker, original, Path.join([directory, "elaborated-0.hl"]), "fresh",
				["--elaborate-generics"]);
			log.add(elaborated.output);
			var same = elaborated.status == 0
				&& File.getBytes(Path.join([directory, "warm-0.hl"]))
				.compare(File.getBytes(Path.join([directory, "elaborated-0.hl"]))) == 0,
				note = knownElaborationDifferences.get(run.test.name);
			if (!same && note == null)
				return {
					status: 1,
					output: 'a build of $source whose generic code is elaborated (--elaborate-generics) '
						+ (elaborated.status == 0 ? 'differs from one that types it again\n' : 'fails\n')
				};
			if (same && note != null)
				return {
					status: 1,
					output: '$source is marked as differing when its generic code is elaborated ($note), but it no longer does: remove the marker\n'
				};
			File.saveBytes(output, File.getBytes(Path.join([directory, 'warm-${edits.length}.hl'])));
			return {status: 0, output: 'compiled $source (warm edit rebuilds) -> $output\n'};
		});
		removeDirectory(directory);
		return {status: result.status, output: log.toString() + result.output};
	}

	static function removeDirectory(path:String):Void {
		if (!FileSystem.exists(path))
			return;
		for (entry in FileSystem.readDirectory(path)) {
			var child = Path.join([path, entry]);
			if (FileSystem.isDirectory(child))
				removeDirectory(child);
			else
				FileSystem.deleteFile(child);
		}
		FileSystem.deleteDirectory(path);
	}

	/**
	 * Programs whose warm edit rebuild is known to differ from a fresh build, by name, with the design item that fixes each. A name here
	 * is an expected failure: the case passes while the rebuild still differs in that way, and FAILS once it stops differing, so the
	 * marker cannot outlive its cause. Nothing else is allowed to fail; do not add a name without a note that explains it.
	 */
	static final warmEditKnownFailures:Map<String, String> = [];

	/**
	 * Programs whose build with `--elaborate-generics` still differs from the plain build, or fails, by name, with what is left to
	 * do for each (`tests/driver/elaboration-known-differences.txt`). A name there must still differ: the build fails once it does
	 * not.
	 */
	final knownElaborationDifferences:Map<String, String>;

	static function readKnownDifferences(path:String):Map<String, String> {
		var known:Map<String, String> = [];
		for (line in File.getContent(path).split("\n")) {
			var tab = line.indexOf("\t");
			if (!StringTools.startsWith(line, "#") && tab > 0)
				known.set(line.substr(0, tab), line.substr(tab + 1));
		}
		return known;
	}

	/** The result for a warm edit build of a program that is marked as a known failure, or null when `run` is not such a build. */
	static function knownWarmFailure(run:ProgramRun, compilation:CommandResult):Null<{passed:Bool, output:String}> {
		var note = run.warm ? warmEditKnownFailures.get(run.test.name) : null;
		if (note == null)
			return null;
		if (compilation.status == 0)
			return {
				passed: false,
				output: compilation.output
					+ 'FAIL: ${runName(run)} is marked as a known failure ($note) but its warm rebuild now equals a fresh build: remove the marker\n'
			};
		if (compilation.output.indexOf("differs from a fresh build") < 0)
			return {
				passed: false,
				output: compilation.output
					+ 'FAIL: ${runName(run)} is marked as a known failure ($note) but failed in another way\n'
			};
		return {passed: true, output: 'PASS: ${runName(run)} is a known failure, as marked ($note)\n'};
	}

	/**
	 * A program, test main or executable case runs in a directory of its own: a fresh one under out/cases, holding a link to every entry of the repository root
	 * except `out`, which is a new directory linking only the native build (out/cmake, the SDK in out/sdk and the libraries), so what a program creates there is its own, and removed afterwards. Relative paths such as `out/x` and `tests/fixtures/...`
	 * resolve there, so what a program writes can never collide with another run of it (the live, plain and warm builds run together)
	 * or with another program, and leaves nothing in the tree. The tree itself is reached only through the links.
	 */
	function startProgram(compiled:String, ?arguments:Array<String>):Process {
		var all = [compiled].concat(arguments == null ? [] : arguments);
		if (Sys.systemName() == "Windows")
			return new Process(hl, all);
		return new Process("sh", [
			"-c",
			"r=$1; shift; mkdir -p \"$r/out/cases\" && d=$(mktemp -d \"$r/out/cases/run.XXXXXX\") || exit 125; for e in \"$r\"/* \"$r\"/.[!.]*; do case \"${e##*/}\" in out|.git) continue;; esac; [ -e \"$e\" ] && ln -s \"$e\" \"$d/\"; done; mkdir \"$d/out\"; for e in \"$r\"/out/cmake \"$r\"/out/sdk \"$r\"/out/*.hdll \"$r\"/out/*.so*; do [ -e \"$e\" ] && ln -s \"$e\" \"$d/out/\"; done; (cd \"$d\" && \"$@\"); s=$?; rm -rf \"$d\"; exit $s",
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
	 *
	 * Each compile types the compiler's sources again, so the mains are built as one program, which runs the main that
	 * HAXEON_NAMED_MAIN names: one compile instead of one per main. The ones in TestCatalog.ownProgramMains are built alone,
	 * and if the shared program does not compile, every main is, so the failure names the main.
	 */
	public function runHaxeMains(tests:Array<NamedCase>, jobs:Int):Int {
		var shared = [
			for (test in tests)
				if (!TestCatalog.ownProgramMains.contains(test.name)) test.name
		];
		var program = shared.length > 1 ? compileSharedMains(shared) : null;
		return runPipelines([for (test in tests) {
			var name = test.name,
				failure = (status:Int) -> status == 0 ? null : 'FAIL: $name exited with $status';
			if (program != null && shared.contains(name)) {steps: [{start: () -> {
				Sys.putEnv(NAMED_MAIN, name);
				startProgram(program);
			},
				failure: failure}],
				success: ""} else {
				var compiled = testMainOutput(name);
				{
					steps:[
						compileMainStep(name, compiled),
						{start: () -> startProgram(compiled), failure: failure}
					],
						success:""
				};
			}
		}], jobs);
	}

	static inline final NAMED_MAIN = "HAXEON_NAMED_MAIN";

	/** Builds `mains` as one program that runs the one HAXEON_NAMED_MAIN names; null, after saying why, when it does not compile. */
	function compileSharedMains(mains:Array<String>):Null<String> {
		var directory = Path.join([root, "out", "test-mains", "shared"]),
			output = Path.join([directory, "NamedMains.hl"]);
		FileSystem.createDirectory(directory);
		var source = new StringBuf();
		source.add("// Generated by tests/driver/TestRunner.hx: runs the named main HAXEON_NAMED_MAIN names.\nclass NamedMains {\n");
		source.add('\tstatic function main():Void {\n\t\tswitch Sys.getEnv("$NAMED_MAIN") {\n');
		for (main in mains)
			source.add('\t\t\tcase "$main": @:privateAccess $main.main();\n');
		source.add("\t\t\tcase name: throw 'no named main ' + name;\n\t\t}\n\t}\n}\n");
		File.saveContent(Path.join([directory, "NamedMains.hx"]), source.toString());
		var command = finishCommand(new Process(haxe, testClassPath().concat([
			"-cp",
			directory,
			"-hl",
			output,
			"-main",
			"NamedMains"
		])));
		if (command.status == 0)
			return output;
		Sys.println(command.output + "the named mains do not compile as one program; compiling each on its own");
		return null;
	}

	public function runExecutables(tests:Array<ExecutableCase>, jobs:Int):Int
		return runPipelines([for (test in tests) executablePipeline(test)], jobs);

	function executablePipeline(test:ExecutableCase):Pipeline {
		var output = Path.join([root, "out", test.output]),
			setupFailure = (status:Int) -> status == 0 ? null : 'FAIL: ${test.name} setup failed',
			steps:Array<PipelineStep> = switch test.compile {
				// These mains are short compiler-API runners: interpreting them beats compiling each to HashLink.
				case HaxeMain(main, arguments):
					[
						{
							start: () -> new Process(haxe,
								haxeMainArguments(main).concat(resolveArguments(output, arguments))),
							failure: setupFailure
						}
					];
				case Hxml(path):
					[
						{
							start: () -> new Process(haxe, ["--cwd", root, Path.join([root, path]), "-hl", output]),
							failure: setupFailure
						}
					];
			},
				expected = test.expectedExit,
				exitDescription = (status:Int) -> expected == null ? 'non-zero exit $status' : 'exit $expected';
		steps.push({
			start: () -> startProgram(output, resolveArguments(output, test.runtimeArguments)),
			failure: status -> (expected == null ? status != 0 : status == expected)
				? null : 'FAIL: ${test.name} expected ${exitDescription(status)}, got $status'
		});
		return {
			steps: steps,
			success: 'PASS: ${test.message} (${expected == null ? "non-zero exit" : 'exit $expected'})'
		};
	}

	/** Output path for a compiled test main; one per case, since several cases share a main. */
	function testMainOutput(name:String):String
		return Path.join([root, "out", "test-mains", name + ".hl"]);

	function compileMainStep(main:String, output:String):PipelineStep
		return {start: () -> {
			FileSystem.createDirectory(Path.directory(output));
			new Process(haxe, testClassPath().concat(["-hl", output, "-main", main]));
		},
			failure: status -> status == 0 ? null : 'FAIL: $main failed to compile'};

	/** Run pipelines on `jobs` workers, reporting each test's output in catalog order. */
	function runPipelines(pipelines:Array<Pipeline>, jobs:Int):Int {
		if (pipelines.length == 0)
			return 0;
		var workerCount = Std.int(Math.max(1, Math.min(jobs, pipelines.length))),
			results:Array<ProgramResult> = [],
			active:Array<ActivePipeline> = [],
			next = 0;
		while (next < pipelines.length || active.length > 0) {
			while (next < pipelines.length && active.length < workerCount) {
				var pipeline = pipelines[next];
				active.push({
					index: next,
					pipeline: pipeline,
					step: 0,
					command: drain(pipeline.steps[0].start()),
					output: ""
				});
				next++;
			}
			var current = active.shift(),
				command = current.command.finish(),
				failure = current.pipeline.steps[current.step].failure(command.status);
			current.output += command.output;
			if (failure != null)
				results[current.index] = {index: current.index, passed: false, output: current.output + failure + "\n"};
			else if (++current.step < current.pipeline.steps.length) {
				current.command = drain(current.pipeline.steps[current.step].start());
				active.push(current);
			} else {
				var success = current.pipeline.success;
				results[current.index] = {
					index: current.index,
					passed: true,
					output: current.output + (success == "" ? "" : success + "\n")
				};
			}
		}
		return reportResults(results);
	}

	public function runProgram(test:ProgramCase):Bool {
		var failed = false;
		for (run in runsOf(test, checkReuse)) {
			var result = runProgramCaptured(run, 0);
			Sys.print(result.output);
			failed = failed || !result.passed;
		}
		closeCompileWorkers();
		return !failed;
	}

	/**
	 * The builds of one program: live and plain, and, when the driver checks reuse (`--check-reuse`), a third that is edited and
	 * rebuilt warm. A cold compile in a fresh process reuses nothing, so only that third build exercises the checks on a program.
	 */
	static function runsOf(test:ProgramCase, checkReuse:Bool):Array<ProgramRun> {
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
		if (checkReuse) {
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
		var runs:Array<ProgramRun> = [for (test in tests) for (run in runsOf(test, checkReuse)) run];
		compileWorkers().prestart(Std.int(Math.max(1, Math.min(jobs, runs.length))));
		var failures = 0;
		if (jobs == 1) {
			for (run in runs) {
				var result = runProgramCaptured(run, 0);
				Sys.print(result.output);
				if (!result.passed)
					failures++;
			}
		} else
			failures = reportResults(runProgramsParallel(runs, Std.int(Math.min(jobs, runs.length))));
		closeCompileWorkers();
		return failures;
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
		var compiling:Array<ActiveCompile> = [];
		while (next < runs.length || compiling.length > 0) {
			while (next < runs.length && compiling.length < jobs) {
				var run = runs[next];
				var source = Path.join([root, "tests", "programs", run.test.name + ".hx"]);
				compiling.push({
					index: next,
					run: run,
					compile: compileProgram(source, runOutput(root, run), run)
				});
				next++;
			}
			var job = compiling.shift();
			var compilation = job.compile.finish();
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

		// A program's builds run one at a time: a program writes the files it names (out/<name>...), and on Windows its runs
		// share one directory, where they would race on them; other programs run alongside.
		var pending = compiled.copy(), active:Array<ActiveProgram> = [];
		while (pending.length > 0 || active.length > 0) {
			while (active.length < jobs) {
				var position = -1;
				for (candidate in 0...pending.length) {
					var name = runs[pending[candidate]].test.name;
					if (!Lambda.exists(active, running -> running.run.test.name == name)) {
						position = candidate;
						break;
					}
				}
				if (position < 0)
					break;
				var index = pending.splice(position, 1)[0], run = runs[index];
				active.push({index: index, run: run, command: drain(startProgram(runOutput(root, run)))});
			}
			var job = active.shift();
			var execution = job.command.finish();
			var expected = job.run.test.expectedExit;
			var passed = execution.status == expected;
			var message = passed ? 'PASS: ${runName(job.run)} source compiled and executed (exit $expected)\n'
				: 'FAIL: ${runName(job.run)} expected exit $expected, got ${execution.status}\n';
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
		var compilation = compileProgram(source, output, run).finish();
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
				output: compilation.output + execution.output
					+ 'FAIL: ${runName(run)} expected exit ${test.expectedExit}, got ${execution.status}\n'
			};
		}
		return {
			index: index,
			passed: true,
			output: compilation.output + execution.output
				+ 'PASS: ${runName(run)} source compiled and executed (exit ${test.expectedExit})\n'
		};
	}

	function runCommand(command:String, arguments:Array<String>):CommandResult {
		return finishCommand(new Process(command, arguments));
	}

	function finishCommand(process:Process):CommandResult
		return drain(process).finish();

	/**
	 * Drains both of `process`'s streams from now until it exits. Reading one to its end while the process fills the other
	 * would wait forever once that pipe is full (on Windows a pipe holds 4 KB), and so would a process started alongside
	 * others whose streams are read only when the driver comes to collect it.
	 */
	static function drain(process:Process):RunningCommand {
		var stdout = "", stderr = "", drained = new sys.thread.Lock();
		sys.thread.Thread.create(() -> {
			stdout = process.stdout.readAll().toString();
			drained.release();
		});
		sys.thread.Thread.create(() -> {
			stderr = process.stderr.readAll().toString();
			drained.release();
		});
		return {finish: () -> {
			drained.wait();
			drained.wait();
			var status = process.exitCode();
			process.close();
			{
				status:status, output:stdout + stderr
			};
		}
		};
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
		// "out" is relative, so a run finds the out of the directory it starts in first; the checkout's own out follows, for a
		// program a test starts in another directory (a watched app in its project).
		var paths = ["out", Path.join([root, "out"]), Path.join([Sys.getEnv("HAXEON_SDK"), "bin"])];
		var variable = Sys.systemName() == "Windows"
			? "PATH" : (Sys.systemName() == "Mac" ? "DYLD_LIBRARY_PATH" : "LD_LIBRARY_PATH");
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
