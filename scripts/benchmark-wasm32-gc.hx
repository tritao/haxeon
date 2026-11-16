#!/usr/bin/env haxeon
/**
 * Times the wasm32 collector: `haxeon scripts/benchmark-wasm32-gc.hx [SAMPLES]` (5 by default, at most 50).
 *
 * Builds tests/programs/wasm-gc-invariants.hx twice for wasm32 with memory statistics: once collecting at every allocation
 * (--wasm-gc-stress), once with the default budget. Then scripts/wasm/benchmark-gc.js runs its allocation-burst,
 * deep-chain and wide-array exports under Node and prints the median time, allocations, collections and linear memory of
 * each, as JSON (the compiler's own output goes to out/wasm-gc-benchmark-compile.log).
 */
import haxe.io.Path;
import haxeon.Script;
import sys.FileSystem;

function main() {
	var samples = Sys.args().length == 0 ? "5" : Sys.args()[0],
		root = Path.directory(Script.directory()),
		out = Path.join([root, "out"]),
		fixture = Path.join([root, "tests", "programs", "wasm-gc-invariants.hx"]),
		stress = Path.join([out, "wasm-gc-benchmark-stress.wasm"]),
		budget = Path.join([out, "wasm-gc-benchmark-budget.wasm"]),
		common = [
			"--target=wasm32",
			"--wasm-memory-stats",
			"--entry=wasm-gc-invariants",
			'--root=${Path.directory(fixture)}'
		];
	FileSystem.createDirectory(out);
	compile(common.concat([
		"--wasm-gc-stress",
		"--export=wasm-gc-invariants.allocationBurst",
		'--output=$stress',
		fixture
	]));
	compile(common.concat([
		"--export=wasm-gc-invariants.allocationBurst", "--export=wasm-gc-invariants.deepGraphExercise",
		"--export=wasm-gc-invariants.wideGraphExercise", '--output=$budget', fixture
	]));
	Script.check("node", [Path.join([Script.directory(), "wasm", "benchmark-gc.js"]), stress, budget, samples]);
}

/** The compiler of this checkout, built through the tool cache; its progress goes to a log, so the output is the JSON. */
function compile(arguments:Array<String>):Void
	Script.check(Script.haxeon(), ["dev", "run", "compiler.tools.HaxeonCompiler"].concat(arguments),
		{log: Path.join([
			Path.directory(Script.directory()),
			"out",
			"wasm-gc-benchmark-compile.log"
		])});
