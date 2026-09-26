#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe_bin="$root_dir/.tools/haxe/haxe"
mkdir -p "$root_dir/out"

if [[ ! -x "$haxe_bin" ]]; then
	echo "missing pinned Haxe; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi
source "$root_dir/scripts/haxeon-compiler.sh"

# The broader GC Bytes fixture includes GC-specific bounds behavior. The shared
# bytes-view fixture checks portable aliasing and copy semantics on both targets.
cases=(objects arrays enums closures dynamic exceptions strings)
for case_name in "${cases[@]}"; do
	source="tests/programs/wasm-gc-$case_name.hx"
	for target in wasm32 wasm-gc; do
		haxeon_compile_async \
			--target="$target" --output="out/wasm-parity-$target-$case_name.wasm" \
			--entry="wasm-gc-$case_name" --root=tests/programs "$source"
	done
done

for target in wasm32 wasm-gc; do
	haxeon_compile_async \
		--target="$target" --output="out/wasm-parity-$target-bytes-compare.wasm" \
		--entry=wasm-bytes-compare --root=tests/programs tests/programs/wasm-bytes-compare.hx
done

# Every program in the manifest runs on both targets and must exit as it does on HL, except
# those listed in wasm-parity-skips.tsv with the reason they cannot yet.
# Compile failures are reported with the other results; skipped programs still compile so the
# suite notices when one starts passing.
mkdir -p "$root_dir/out/wasm-parity-logs"
while IFS=$'\t' read -r case_name _; do
	[[ -z $case_name || $case_name == \#* ]] && continue
	for target in wasm32 wasm-gc; do
		output="out/wasm-parity-$target-$case_name.wasm"
		rm -f "$root_dir/$output"
		haxeon_compile_logged_async "$root_dir/out/wasm-parity-logs/$target-$case_name.log" \
			--target="$target" --output="$output" --entry="$case_name" --root=tests/programs "tests/programs/$case_name.hx"
	done
done < "$root_dir/tests/programs/expected-exits.tsv"

haxeon_compile_async \
	--target=wasm32 --wasm-gc-stress --output=out/wasm-parity-wasm32-bytes-view-stress.wasm \
	--entry=bytes-view --root=tests/programs tests/programs/bytes-view.hx

cases+=(bytes-compare)
haxeon_compile_wait

node - "$root_dir" "${cases[@]}" <<'JS'
const fs = require("fs");
const path = require("path");
const root = process.argv[2];
const gcCases = process.argv.slice(3);

function table(file) {
  return fs.readFileSync(path.join(root, "tests", "programs", file), "utf8").split("\n")
    .filter(line => line.trim() !== "" && !line.startsWith("#")).map(line => line.split("\t"));
}

const modes = new Map(table("wasm-parity-skips.tsv").map(([name, mode]) => [name, mode]));
const cases = gcCases.map(name => ({name, expected: 42}))
  .concat(table("expected-exits.tsv").map(([name, expected]) => ({name, expected: Number(expected)})));
for (const name of modes.keys())
  if (!cases.some(entry => entry.name === name))
    throw new Error(`wasm-parity-skips.tsv lists ${name}, which is not in expected-exits.tsv`);

// Host functions of the haxeon_runtime ABI, matching native/runtime/core.c.
const runtime = {
  __math_ceil: Math.ceil,
  __math_floor: Math.floor,
  __math_round: value => Math.floor(value + 0.5) | 0,
  __math_pow: Math.pow,
  __math_sqrt: Math.sqrt,
  __math_fmod: (value, modulus) => value % modulus,
  __math_sin: Math.sin,
  __math_cos: Math.cos,
  __math_tan: Math.tan,
  __math_atan2: Math.atan2,
  __std_int_f64: Math.trunc
};

async function run(name, target, mode) {
  const file = path.join(root, "out", `wasm-parity-${target}-${name}.wasm`);
  if (!fs.existsSync(file)) {
    const log = path.join(root, "out", "wasm-parity-logs", `${target}-${name}.log`);
    const text = fs.existsSync(log) ? fs.readFileSync(log, "utf8") : "";
    const reason = text.split("\n").find(line => /Uncaught exception|: E\d{4}:/.test(line)) ?? "";
    return {failure: `did not compile: ${reason.replace(/^.*(Uncaught exception |E\d{4}: )/, "").slice(0, 120)}`};
  }
  const module = new WebAssembly.Module(fs.readFileSync(file));
  const imports = WebAssembly.Module.imports(module);
  const missing = imports.filter(entry => entry.module !== "haxeon_runtime" || !(entry.name in runtime));
  if (missing.length !== 0)
    return {failure: `imports ${missing.map(entry => `${entry.module}.${entry.name}`).join(", ")}`};
  if (target === "wasm-gc") {
    if (mode !== "gc-memory" && WebAssembly.Module.exports(module).some(entry => entry.name === "memory"))
      return {failure: "GC module contains linear memory"};
    if (WebAssembly.Module.customSections(module, "haxeon.gc.roots").length !== 0)
      return {failure: "GC module contains custom root metadata"};
  }
  const instance = await WebAssembly.instantiate(module, {haxeon_runtime: runtime});
  try {
    return {exit: instance.exports.main()};
  } catch (error) {
    // An uncaught Haxe exception ends the program with status 1, as on HL.
    if (error instanceof WebAssembly.Exception)
      return {exit: 1};
    return {failure: `trap: ${error.message}`};
  }
}

(async () => {
  const failures = [];
  let skipped = 0;
  for (const {name, expected} of cases) {
    const mode = modes.get(name);
    const results = {};
    for (const target of ["wasm32", "wasm-gc"]) {
      const result = await run(name, target, mode);
      if (result.failure === undefined && result.exit !== expected)
        result.failure = `expected ${expected}, got ${result.exit}`;
      results[target] = result;
    }
    const passing = results.wasm32.failure === undefined && results["wasm-gc"].failure === undefined;
    if (mode === "skip") {
      skipped++;
      if (passing)
        failures.push(`${name}: passes on both targets; remove it from tests/programs/wasm-parity-skips.tsv`);
      continue;
    }
    for (const target of ["wasm32", "wasm-gc"])
      if (results[target].failure !== undefined)
        failures.push(`${name} (${target}): ${results[target].failure}`);
  }
  const stressBytes = fs.readFileSync(path.join(root, "out", "wasm-parity-wasm32-bytes-view-stress.wasm"));
  const stressInstance = await WebAssembly.instantiate(stressBytes, {});
  if (stressInstance.instance.exports.main() !== 42)
    failures.push("bytes-view (wasm32 stress GC): view failed to retain and alias its source");
  if (failures.length !== 0)
    throw new Error(`Wasm parity failures:\n  ${failures.join("\n  ")}`);
  console.log(`PASS: ${cases.length - skipped} Haxe fixtures agree across Wasm32, Wasm GC and HL (${skipped} skipped)`);
})().catch(error => {
  console.error(error.message ?? error);
  process.exitCode = 1;
});
JS
