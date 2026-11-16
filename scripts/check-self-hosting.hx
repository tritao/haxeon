#!/usr/bin/env haxeon
/**
 * Checks that the compiler in this tree can build itself, to a fixed point, in about a minute and a half:
 * `haxeon scripts/check-self-hosting.hx`.
 *
 * The seed is built by running the compiler sources under the pinned Haxe interpreter; stage 1 is built by the seed and stage
 * 2 by stage 1. Stages 1 and 2 must be identical. Unlike `haxeon dev bootstrap --self` this does not use the checked-in
 * compiler, so it also catches a change that the sources can no longer be built with.
 */
import haxe.io.Path;
import haxeon.Script;
import sys.FileSystem;

function main() {
	// Every entry point that ships or that the tools run is built by the self-hosted compiler, so a construct Haxeon does not
	// compile cannot slip into one unnoticed. An entry with a known gap is listed with why it does not build yet; the check
	// fails once it builds, so the list is cut as gaps close.
	var buildingEntries = [
		"compiler.tools.HaxeonCompiler", "Main", "FfiImportMain", "FfiAuditMain", "EditorServiceMain",
		"compiler.tools.CompilerServer", "build.HaxeonBuild", "tools.HaxeonCli", "LspMain"
	];
	var entryGaps:Map<String, String> = [];
	var root = Path.directory(Script.directory()),
		haxe = Path.join([root, ".tools", "haxe", Sys.systemName() == "Windows" ? "haxe.exe" : "haxe"]),
		hl = Script.vm(),
		work = Path.join([root, "out", "self-hosting"]);
	if (!FileSystem.exists(haxe))
		Script.fail("missing local toolchain; run scripts/bootstrap-tools.sh first");
	FileSystem.createDirectory(work);

	var sources = Path.join([work, "compiler-sources.txt"]);
	sys.io.File.saveContent(sources, sourceList(root, ["src", "stdlib"]));
	var arguments = ["--entry=compiler.tools.HaxeonCompiler", "--root=src", "--root=stdlib", '--sources-file=$sources'];

	Sys.println("seed: building the compiler with the Haxe interpreter");
	step(haxe, ["--cwd", root, "common.hxml", "--run", "compiler.tools.HaxeonCompiler",
		'--output=$work/seed.hl'].concat(arguments),
		root, '$work/seed.log', "the compiler sources do not build under the Haxe interpreter");
	var previous = '$work/seed.hl';
	for (stage in 1...3) {
		Sys.println('stage $stage: building the compiler with ${Path.withoutDirectory(previous)}');
		step(hl, [previous, '--output=$work/stage-$stage.hl'].concat(arguments), root, '$work/stage-$stage.log',
			'${Path.withoutDirectory(previous)} could not build the compiler sources');
		previous = '$work/stage-$stage.hl';
	}
	for (suffix in ["", ".functions"])
		if (!Script.sameContent('$work/stage-1.hl$suffix', '$work/stage-2.hl$suffix'))
			Script.fail('FAIL: stage 1 and stage 2 differ ($work/stage-1.hl$suffix, $work/stage-2.hl$suffix)');
	Sys.println("PASS: the compiler builds itself to a fixed point");

	var entrySources = Path.join([work, "entry-sources.txt"]);
	sys.io.File.saveContent(entrySources, sourceList(root, ["src", "stdlib", "lib/haxeon-io"]));
	function buildEntry(entry:String):Int
		return Script.run(hl, [
			'$work/stage-1.hl', '--entry=$entry', "--root=src", "--root=stdlib", "--root=lib/haxeon-io",
			'--sources-file=$entrySources', '--output=$work/entry-$entry.hl'
		], {
			cwd: root,
			log: '$work/entry-$entry.log'
		});
	for (entry in buildingEntries)
		if (buildEntry(entry) != 0) {
			Sys.stderr().writeString(Script.tail('$work/entry-$entry.log', 5) + "\n");
			Script.fail('FAIL: the self-hosted compiler does not build $entry');
		}
	for (entry => why in entryGaps)
		if (buildEntry(entry) == 0)
			Script.fail('FAIL: $entry now builds with the self-hosted compiler ($why); move it to buildingEntries');
	Sys.println('PASS: the self-hosted compiler builds ${buildingEntries.length} entry points; ${Lambda.count(entryGaps)} have known gaps');

	// A fixed point says the stages agree, not that they are right: a miscompilation the self-hosted compiler repeats when it
	// builds itself passes every check above. The program cases state their expected results, so compiling them all with the
	// self-hosted Main catches one wherever a case exercises it.
	Sys.println("programs: compiling the program cases with the self-hosted Main");
	var programsLog = '$work/programs.log';
	if (Script.run(Script.haxeon(), ["dev", "test-driver", Std.string(processorCount()), "--suite", "programs"],
		{
			cwd: root,
			env: ["HAXEON_MAIN_HL" => '$work/entry-Main.hl'],
			log: programsLog
		}) != 0) {
		var failures = [for (line in sys.io.File.getContent(programsLog).split("\n")) if (StringTools.startsWith(line,
			"FAIL")) line];
		Sys.stderr().writeString(failures.slice(0, 20).join("\n") + "\n" + Script.tail(programsLog, 3) + "\n");
		Script.fail("FAIL: the program cases do not all pass when the self-hosted Main compiles them");
	}
	var summary = Script.tail(programsLog, 1);
	Sys.println('PASS: the self-hosted Main passes the program cases (${StringTools.replace(summary, "Test driver: ", "")})');

	// The same equality semantics through a stock-Haxe-built compiler and the self-hosted compiler.
	Sys.println("equality guard: building the compiler with stock Haxe");
	var haxeBuiltCompiler = Script.output(Script.haxeon(), ["dev", "tool-path", "compiler.tools.HaxeonCompiler"]),
		fixture = Path.join([root, "tests", "programs", "equality-self-hosting-guard.hx"]);
	for (compiler in [haxeBuiltCompiler, '$work/stage-1.hl'])
		for (inlining in ["0", "1"])
			for (target in ["hl", "wasm32", "wasm-gc"]) {
				var output = '$work/equality-${Path.withoutDirectory(compiler)}-$target-$inlining.bin',
					which = '($compiler, $target, inline=$inlining)';
				step(hl, [
					compiler, '--target=$target', "--entry=equality-self-hosting-guard", "--root=tests/programs",
					'--output=$output', fixture
				], root, '$work/equality-guard.log', 'equality guard did not compile $which',
					["HAXEON_INLINE" => inlining]);
				if (target == "hl") {
					var status = Script.run(hl, [output]);
					if (status != 42)
						Script.fail('FAIL: equality guard returned $status $which');
				} else if (Script.run("node", [Path.join([root, "tests", "runtime", "run-equality-guard.js"]), output])
					!= 0)
					Script.fail('FAIL: equality guard $which');
			}
	Sys.println("PASS: Haxe-built and self-hosted compilers agree on equality across all targets");
	// Exercise the scalar closure planner with the self-hosted compiler.
	var closureFixture = Path.join([root, "tests", "programs", "scalar-closure-boundaries.hx"]),
		closureOutput = '$work/scalar-closure-boundaries.wasm';
	step(hl, ['$work/stage-1.hl', "--target=wasm-gc", "--entry=scalar-closure-boundaries",
		"--root=tests/programs", '--output=$closureOutput', closureFixture], root,
		'$work/scalar-closure-boundaries.log', "self-hosted compiler could not build the scalar closure boundary fixture");
	var closureCheck = 'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;const n=e.main();if(n!==42)throw Error("scalar closure boundary returned "+n)';
	if (Script.run("node", ["-e", closureCheck, closureOutput]) != 0)
		Script.fail("FAIL: scalar closure boundary fixture failed under the self-hosted compiler");
	Sys.println("PASS: self-hosted compiler preserves the Wasm scalar closure boundary");
	if (Script.run("bash", [Path.join([root, "tests", "integration", "test-compiler-embedding.sh"])], {cwd: root}) != 0)
		Script.fail("FAIL: the embedded compiler check failed");
}

/** Runs one build step with its output in `log`; on failure shows the log's end and stops with `failure`. */
function step(command:String, arguments:Array<String>, cwd:String, log:String, failure:String,
		?env:Map<String, String>):Void {
	if (Script.run(command, arguments, {cwd: cwd, log: log, env: env}) != 0) {
		Sys.stderr().writeString(Script.tail(log, 20) + "\n");
		Script.fail('FAIL: $failure');
	}
}

/** The `.hx` files under `directories` of `root`, one path per line relative to it, in byte order (as `LC_ALL=C sort`). */
function sourceList(root:String, directories:Array<String>):String {
	var paths = [
		for (directory in directories)
			for (file in Script.files(Path.join([root, directory]), ".hx")) '$directory/$file'
	];
	paths.sort((left, right) -> left < right ? -1 : left > right ? 1 : 0);
	return paths.join("\n") + "\n";
}

/** The processors to run the driver's jobs on: NUMBER_OF_PROCESSORS on Windows, `getconf` elsewhere, else 4. */
function processorCount():Int {
	var count = Sys.systemName() == "Windows" ? Std.parseInt(Sys.getEnv("NUMBER_OF_PROCESSORS") ?? "") : null;
	if (count == null) {
		var log = Path.join([Script.directory(), "..", "out", "self-hosting", "processors.txt"]);
		if (Script.run("getconf", ["_NPROCESSORS_ONLN"], {log: log}) == 0)
			count = Std.parseInt(StringTools.trim(sys.io.File.getContent(log)));
	}
	return count == null || count < 1 ? 4 : count;
}
