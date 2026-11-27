#!/usr/bin/env haxeon
/**
 * The UI value-type fixtures on HashLink, Wasm32 and Wasm GC, with and without inlining: `haxeon
 * packages/ui/tools/test-value-snapshot-parity.hx [GROUP...]`. Each group's entry must build and return 42 everywhere, and
 * every other fixture in tests/value-types is one of its implicit raw-value conversions, which must be rejected with its
 * type error on HashLink and on Wasm. This UI graph reaches higher-order closure adapters that the Showcase does not.
 * Programs run `TEST_JOBS` at a time (4 by default: each compile holds the whole UI).
 */
import haxe.io.Path;
import haxeon.Script;
import haxeon.Script.ScriptJob;
import sys.FileSystem;
import sys.io.File;

class Fixtures {
	public static final GROUPS = [
		"local-snapshot", "host-lifecycle", "style-kinds", "cursor-shape", "layout-codes", "layout-policies",
		"text-codes", "widget-kinds",
		"presentation-kinds", "native-boundary-kinds", "ui-flags"
	];

	public static final MEMORY_CONTRACT =
		'{"name":"nativekit-haxeon-linear-memory","version":1,"address_model":"wasm32","page_size":65536,"host_base":0,'
		+ '"host_limit":134217728,"guest_base":134217728,"guest_limit":268435456,"memory_size":268435456}';

	/** Instantiates a Wasm module with no host but Math, and checks that main() returns 42. */
	public static final WASM_RUNNER =
		'const fs = require("fs");
(async () => {
  const [file, label] = process.argv.slice(2);
  const module = new WebAssembly.Module(fs.readFileSync(file));
  const imports = {env: {memory: new WebAssembly.Memory({initial: 4096, maximum: 4096})}};
  for (const entry of WebAssembly.Module.imports(module)) {
    if (entry.kind !== "function") continue;
    const group = imports[entry.module] ??= {};
    const mathName = entry.name.replace(/^__math_/, "");
    if (entry.module === "haxeon_runtime" && entry.name.startsWith("__math_") &&
        (mathName === "is_finite" || typeof Math[mathName] === "function")) {
      group[entry.name] = mathName === "is_finite" ? Number.isFinite : Math[mathName];
    } else {
      group[entry.name] = () => { throw new Error(`Unexpected host call: $${entry.module}.$${entry.name}`); };
    }
  }
  const instance = await WebAssembly.instantiate(module, imports);
  const result = instance.exports.main();
  if (result !== 42) throw new Error(`$${label} returned $${result}`);
})().catch(error => { console.error(error); process.exitCode = 1; });
';
}

function main() {
	var root = FileSystem.absolutePath(Path.join([Script.directory(), "..", "..", ".."])),
		ui = Path.join([root, "packages", "ui"]),
		fixtures = Path.join([ui, "tests", "value-types"]),
		hl = Script.vm(),
		work = Path.join([root, "out", "ui-value-parity"]);
	var compiler = Sys.getEnv("HAXEON_COMPILER_HL");
	if (compiler == null || compiler == "")
		compiler = Script.output(Script.haxeon(), ["dev", "tool-path", "compiler.tools.HaxeonCompiler"]);
	FileSystem.createDirectory(work);
	var memory = Path.join([work, "memory.json"]), runner = Path.join([work, "run-wasm.js"]);
	File.saveContent(memory, Fixtures.MEMORY_CONTRACT + "\n");
	File.saveContent(runner, Fixtures.WASM_RUNNER);

	var groups = Sys.args().length > 0 ? Sys.args() : Fixtures.GROUPS;
	for (group in groups)
		if (Fixtures.GROUPS.indexOf(group) < 0)
			Script.fail('Unknown UI value fixture group: $group', 2);
	// Every fixture that is not a group's entry is a conversion one of the groups must reject.
	var rejected = [for (file in Script.files(fixtures, ".hx")) {
		var name = Path.withoutExtension(file);
		if (Fixtures.GROUPS.indexOf(name) < 0
			&& Lambda.exists(groups, group -> StringTools.startsWith(name, group + "-")))
			name;
	}];
	var nativeLibraries = [
		Path.join([root, "out"]),
		Path.directory(hl),
		Path.join([root, "out", "packages", "ui", "native"])
	];
	var inherited = Sys.getEnv("LD_LIBRARY_PATH");
	if (inherited != null && inherited != "")
		nativeLibraries.push(inherited);
	var env = ["LD_LIBRARY_PATH" => nativeLibraries.join(":")];

	var parallel = Script.jobs(4);
	function options(target:String, inlining:Bool):Array<String> {
		var wasm = target != "hl";
		return (inlining ? [] : ["--no-inline"]).concat(wasm ? [
			'--target=$target',
			"--wasm-import-memory",
			'--wasm-memory-contract=$memory'
		] : []).concat([
			'--root=$fixtures', '--root=$ui/src', '--root=$root/packages/editor/src',
			'--root=$root/packages/platform/src',
			'--ffi-interface=$root/packages/platform/bindings/nativekit.hxi',
			'--ffi-projection=$root/packages/platform/bindings/nativekit.hxmap',
			'--ffi-interface=$root/packages/platform/bindings/nativekit-net.hxi',
			'--ffi-projection=$root/packages/platform/bindings/nativekit-net.hxmap',
			'--ffi-interface=$ui/bindings/nativekit-ui.hxi',
			'--ffi-projection=$ui/bindings/nativekit-ui.hxmap'
		]);
	}
	function compile(target:String, inlining:Bool, entry:String, output:String, log:String):ScriptJob
		return {
			command: hl,
			arguments: [compiler].concat(options(target, inlining)).concat([
				'--entry=$entry', '--output=$output', Path.join([
					fixtures,
					'$entry.hx'
				])
			]),
			options: {env: env, log: log}
		};

	// Each group's entry builds and returns 42 on every target, with and without inlining.
	var builds:Array<{entry:String, label:String, target:String, inlining:Bool, artifact:String, log:String}> = [];
	for (inlining in [false, true])
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (entry in groups) {
				var name = '$entry-${inlining ? 1 : 0}-$target';
				builds.push({
					entry: entry,
					label: '$target, inline=${inlining ? 1 : 0}',
					target: target,
					inlining: inlining,
					artifact: Path.join([work, '$name.${target == "hl" ? "hl" : "wasm"}']),
					log: Path.join([work, '$name.log'])
				});
			}
	var built = Script.runAll([
		for (build in builds)
			compile(build.target, build.inlining, build.entry, build.artifact, build.log)
	], parallel);
	for (index in 0...builds.length)
		if (built[index] != 0)
			Script.fail('FAIL: ${builds[index].entry} does not build on ${builds[index].label}:\n${File.getContent(builds[index].log)}');
	var ran = Script.runAll([
		for (build in builds)
			build.target == "hl" ? {
				command: hl,
				arguments: [build.artifact],
				options: {env: env, log: build.log + ".run"}
			} : {
				command: "node",
				arguments: [runner, build.artifact, build.label],
				options: {env: env, log: build.log + ".run"}
			}
	], parallel);
	for (index in 0...builds.length) {
		var build = builds[index];
		if (ran[index] != (build.target == "hl" ? 42 : 0))
			Script.fail('FAIL: ${build.entry} on ${build.label} exited with ${ran[index]}:\n${File.getContent(build.log + ".run")}');
		Sys.println('PASS: ${build.entry} on ${build.label}');
	}

	// Every other fixture is a conversion the typer rejects, which no backend or inlining setting reaches: it is checked once
	// on HashLink and once on Wasm, whose standard library differs.
	var checks:Array<{entry:String, target:String, log:String}> = [
		for (target in ["hl", "wasm32"])
			for (entry in rejected)
			{entry: entry, target: target, log: Path.join([work, 'rejected-$entry-$target.log'])}
	];
	var rejections = Script.runAll([
		for (check in checks)
			compile(check.target, true, check.entry,
			Path.join([work, 'rejected-${check.entry}.${check.target == "hl" ? "hl" : "wasm"}']), check.log)
	], parallel);
	for (index in 0...checks.length) {
		var check = checks[index];
		if (rejections[index] == 0)
			Script.fail('FAIL: ${check.entry} accepted an implicit raw-value conversion on ${check.target}');
		var integerProperty = check.entry == "layout-policies-integer-property",
			expected = integerProperty
				? 'E1009: Type mismatch for argument 1 to "haxeon.ui.style.ComputedStyle.setInteger"'
				: 'E1002: Type mismatch for local "state"';
		// The status alone would pass a compiler that failed for any other reason, so the rejection must be this one.
		if (File.getContent(check.log).indexOf(expected) < 0)
			Script.fail('FAIL: ${check.entry} was rejected on ${check.target} without "$expected":\n${File.getContent(check.log)}');
		Sys.println('PASS: ${check.entry} rejects ${integerProperty ? "integer writes to an enum property" : "implicit raw-value conversion"} on ${check.target}');
	}
}
