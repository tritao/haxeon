#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe_bin="$root_dir/.tools/haxe/haxe"
mkdir -p "$root_dir/out"

if [[ ! -x "$haxe_bin" ]]; then
	echo "missing pinned Haxe; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

# The full GC Bytes fixture also checks aliasing Bytes.view, which Linear32
# still copies. Keep that runtime-only case separate and compare shared Bytes
# ordering semantics here.
cases=(objects arrays enums closures dynamic exceptions strings)
for case_name in "${cases[@]}"; do
	source="tests/programs/wasm-gc-$case_name.hx"
	for target in wasm32 wasm-gc; do
		"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
			--target="$target" --output="out/wasm-parity-$target-$case_name.wasm" \
			--entry="wasm-gc-$case_name" --root=tests/programs "$source"
	done
done

for target in wasm32 wasm-gc; do
	"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
		--target="$target" --output="out/wasm-parity-$target-bytes-compare.wasm" \
		--entry=wasm-bytes-compare --root=tests/programs tests/programs/wasm-bytes-compare.hx
done

shared_cases=(add call-many function-call function-value lambda single-argument-lambda contextual-callbacks enum-array-pattern anonymous-function enum-abstract computed-property
	mutable-capture nested-mutable-capture captured-lambda captured-this nullable-basic nullable-compound object-array for-in loop-control modulo switch-enum
	multiple-implements captured-method anonymous-record array-comprehension filtered-array-comprehension range-iteration cast-expression optional-argument-forwarding
	default-parameter-inference generic-functions generic-abstract bounded-generic generic-class inheritance-class override-method virtual-dispatch array-iterator-wasm array-slice-index array-growth-wasm array-alias-growth array-index-growth array-resize array-expression-mutation array-field-mutation
	array-copy-concat array-unshift array-insert array-splice array-remove array-object-mutation array-reverse dynamic-equality numeric-promotion function-wrapper std-is-of-type
	map-basic map-int map-primitive-types map-literal map-object map-anonymous-enum map-for-in map-key-value-for-in map-comprehension map-nullable-get nullable-map-get map-string-equality
	try-catch try-nested try-array-bounds concise-try try-typed-class try-typed-mismatch try-typed-int try-multiple-catches reflect-compare-sort generic-contextual-callback)
for case_name in "${shared_cases[@]}"; do
	for target in wasm32 wasm-gc; do
		"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
			--target="$target" --output="out/wasm-parity-$target-$case_name.wasm" \
			--entry="$case_name" --root=tests/programs "tests/programs/$case_name.hx"
	done
done

cases+=(bytes-compare "${shared_cases[@]}")

node - "$root_dir" "${cases[@]}" <<'JS'
const fs = require("fs");
const path = require("path");
const root = process.argv[2];
const cases = process.argv.slice(3);
const expectedResults = { "array-object-mutation": 8, "array-field-mutation": 11, "single-argument-lambda": 43, "mutable-capture": 78, "nested-mutable-capture": 3, "inheritance-class": 43, "map-for-in": 52, "virtual-dispatch": 71 };

(async () => {
  for (const name of cases) {
    const results = {};
    for (const target of ["wasm32", "wasm-gc"]) {
      const file = path.join(root, "out", `wasm-parity-${target}-${name}.wasm`);
      const bytes = fs.readFileSync(file);
      const module = new WebAssembly.Module(bytes);
      if (target === "wasm-gc") {
        const imports = WebAssembly.Module.imports(module);
        const exports = WebAssembly.Module.exports(module);
        if (imports.length !== 0 || exports.some(entry => entry.name === "memory")
            || WebAssembly.Module.customSections(module, "haxeon.gc.roots").length !== 0)
          throw new Error(`${name}: GC module contains linear memory or custom root metadata`);
      }
      const imports = target === "wasm32"
        ? { haxeon_runtime: {
            __math_ceil: value => Math.ceil(value),
            __std_int_f64: value => Math.trunc(value)
          } }
        : {};
      const instance = await WebAssembly.instantiate(module, imports);
      results[target] = instance.exports.main();
      const expected = expectedResults[name] ?? 42;
      if (results[target] !== expected)
        throw new Error(`${name} (${target}): expected ${expected}, got ${results[target]}`);
    }
    if (results.wasm32 !== results["wasm-gc"])
      throw new Error(`${name}: Wasm32 returned ${results.wasm32}, Wasm GC returned ${results["wasm-gc"]}`);
  }
  console.log(`PASS: ${cases.length} Haxe fixtures agree across Wasm32 and Wasm GC`);
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
JS
