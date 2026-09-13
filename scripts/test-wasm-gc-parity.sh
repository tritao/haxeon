#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe_bin="$root_dir/.tools/haxe/haxe"
mkdir -p "$root_dir/out"

if [[ ! -x "$haxe_bin" ]]; then
	echo "missing pinned Haxe; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

cases=(objects arrays enums closures dynamic exceptions strings)
for case_name in "${cases[@]}"; do
	source="tests/programs/wasm-gc-$case_name.hx"
	for target in wasm32 wasm-gc; do
		"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
			--target="$target" --output="out/wasm-parity-$target-$case_name.wasm" \
			--entry="wasm-gc-$case_name" --root=tests/programs "$source"
	done
done

node - "$root_dir" "${cases[@]}" <<'JS'
const fs = require("fs");
const path = require("path");
const root = process.argv[2];
const cases = process.argv.slice(3);

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
      const instance = await WebAssembly.instantiate(module, {});
      results[target] = instance.exports.main();
      if (results[target] !== 42)
        throw new Error(`${name} (${target}): expected 42, got ${results[target]}`);
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
