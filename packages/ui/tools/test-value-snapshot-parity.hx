#!/usr/bin/env haxeon
/**
 * The UI value-type fixtures on HashLink, Wasm32 and Wasm GC, with and without inlining: `haxeon
 * packages/ui/tools/test-value-snapshot-parity.hx [GROUP...]`. Each group's entry must build and return 42, and every other
 * fixture in tests/value-types is one of its implicit raw-value conversions, which must be rejected with its type error. This
 * UI graph reaches higher-order closure adapters that the Showcase does not.
 */
import haxe.io.Path;
import haxeon.Script;
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

	for (inlining in [false, true])
		for (target in ["hl", "wasm32", "wasm-gc"]) {
			var wasm = target != "hl", suffix = wasm ? "wasm" : "hl", bindings = wasm ? "-wasm" : "";
			var options = (inlining ? [] : ["--no-inline"]).concat(wasm ? [
				'--target=$target',
				"--wasm-import-memory",
				'--wasm-memory-contract=$memory'
			] : []).concat([
				'--root=$fixtures', '--root=$ui/haxe', '--root=$ui/bindings/haxe', '--root=$root/packages/editor/src',
				'--root=$root/packages/platform/src',
				'--ffi-interface=$root/packages/platform/bindings/nativekit$bindings.hxi',
				'--ffi-projection=$root/packages/platform/bindings/nativekit.hxmap',
				'--ffi-interface=$root/packages/platform/bindings/nativekit-net$bindings.hxi',
				'--ffi-projection=$root/packages/platform/bindings/nativekit-net.hxmap',
				'--ffi-interface=$ui/bindings/nativekit-ui$bindings.hxi',
				'--ffi-projection=$ui/bindings/nativekit-ui.hxmap'
			]);
			var label = '$target, inline=${inlining ? 1 : 0}';
			function compile(entry:String, output:String, log:String):Int
				return Script.run(hl, [compiler].concat(options).concat([
					'--entry=$entry', '--output=$output', Path.join([
						fixtures,
						'$entry.hx'
					])
				]), {
					env: env,
					log: log
				});

			for (entry in groups) {
				var artifact = Path.join([work, '$entry-${inlining ? 1 : 0}-$target.$suffix']),
					log = Path.join([work, "compile.log"]);
				if (compile(entry, artifact, log) != 0)
					Script.fail('FAIL: $entry does not build on $label:\n${File.getContent(log)}');
				var status = wasm ? Script.run("node", [runner, artifact, label], {env: env}) : Script.run(hl,
					[artifact], {env: env});
				if (status != (wasm ? 0 : 42))
					Script.fail('FAIL: $entry on $label exited with $status');
				Sys.println('PASS: $entry on $label');
			}
			for (entry in rejected) {
				var log = Path.join([work, "rejected.log"]);
				if (compile(entry, Path.join([work, 'rejected.$suffix']), log) == 0)
					Script.fail('FAIL: $entry accepted an implicit raw-value conversion on $label');
				var integerProperty = entry == "layout-policies-integer-property",
					expected = integerProperty
						? 'E1009: Type mismatch for argument 1 to "haxeon.ui.style.ComputedStyle.setInteger"'
						: 'E1002: Type mismatch for local "state"';
				// The status alone would pass a compiler that failed for any other reason, so the rejection must be this one.
				if (File.getContent(log).indexOf(expected) < 0)
					Script.fail('FAIL: $entry was rejected on $label without "$expected":\n${File.getContent(log)}');
				Sys.println('PASS: $entry rejects ${integerProperty ? "integer writes to an enum property" : "implicit raw-value conversion"} on $label');
			}
		}
}
