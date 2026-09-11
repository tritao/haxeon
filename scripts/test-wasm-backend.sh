#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe_bin="$root_dir/.tools/haxe/haxe"
if [[ ! -x "$haxe_bin" ]]; then
	echo "missing pinned Haxe; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

"$haxe_bin" --cwd "$root_dir" -cp src -cp tests/compiler --run WasmBackendMain
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --output=out/wasm-cli-backend.wasm --entry=add \
	--root=tests/programs tests/programs/add.hx
node - "$root_dir" <<'JS'
const fs = require("fs");
const root = process.argv[2];
const cases = [
  ["out/wasm-backend-test.wasm", 42],
  ["out/wasm-backend-branch.wasm", 42],
  ["out/wasm-backend-loop.wasm", 6],
  ["out/wasm-backend-object.wasm", 42],
  ["out/wasm-backend-array.wasm", 42],
  ["out/wasm-backend-float-array.wasm", 42],
  ["out/wasm-backend-array-ops.wasm", 42],
  ["out/wasm-backend-array-mutation.wasm", 42],
  ["out/wasm-backend-string.wasm", 6],
  ["out/wasm-backend-string-ops.wasm", 42],
  ["out/wasm-backend-method.wasm", 42],
  ["out/wasm-backend-global.wasm", 42],
  ["out/wasm-backend-float-global.wasm", 42],
  ["out/wasm-backend-enum.wasm", 42],
  ["out/wasm-backend-float-enum.wasm", 42],
  ["out/wasm-backend-inherited-field.wasm", 42],
  ["out/wasm-cli-backend.wasm", 42],
  ["out/wasm-backend-closure.wasm", 42],
  ["out/wasm-backend-instance-closure.wasm", 42],
  ["out/wasm-backend-virtual.wasm", 42]
];
(async () => {
  for (const [relative, expected] of cases) {
    const bytes = fs.readFileSync(`${root}/${relative}`);
    const {instance} = await WebAssembly.instantiate(bytes);
    const value = instance.exports.main();
    if (value !== expected)
      throw new Error(`${relative}: expected ${expected}, got ${value}`);
  }
  console.log("PASS: Wasm modules validate and execute");
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
JS
