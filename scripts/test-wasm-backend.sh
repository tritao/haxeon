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
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --output=out/wasm-cli-dynamic.wasm --entry=dynamic-equality \
	--root=tests/programs tests/programs/dynamic-equality.hx
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --output=out/wasm-cli-type-test.wasm --entry=std-is-of-type \
	--root=tests/programs tests/programs/std-is-of-type.hx
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --output=out/wasm-cli-array-slice.wasm --entry=array-slice-index \
	--root=tests/programs tests/programs/array-slice-index.hx
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --output=out/wasm-cli-array-mutation.wasm --entry=array-splice \
	--root=tests/programs tests/programs/array-splice.hx
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --output=out/wasm-cli-array-growth.wasm --entry=array-growth-wasm \
	--root=tests/programs tests/programs/array-growth-wasm.hx
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --output=out/wasm-cli-map-basic.wasm --entry=map-basic \
	--root=tests/programs tests/programs/map-basic.hx
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --output=out/wasm-cli-map-int.wasm --entry=map-int \
	--root=tests/programs tests/programs/map-int.hx
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --output=out/wasm-cli-map-primitive-types.wasm --entry=map-primitive-types \
	--root=tests/programs tests/programs/map-primitive-types.hx
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --output=out/wasm-cli-map-for-in.wasm --entry=map-for-in \
	--root=tests/programs tests/programs/map-for-in.hx
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --output=out/wasm-cli-map-key-value-for-in.wasm --entry=map-key-value-for-in \
	--root=tests/programs tests/programs/map-key-value-for-in.hx
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --output=out/wasm-cli-map-object.wasm --entry=map-object \
	--root=tests/programs tests/programs/map-object.hx
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --output=out/wasm-cli-map-anonymous-enum.wasm --entry=map-anonymous-enum \
	--root=tests/programs tests/programs/map-anonymous-enum.hx
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --output=out/wasm-cli-cnative-import.wasm --entry=wasm-cnative-import \
	--root=tests tests/wasm-cnative-import.hx
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --output=out/wasm-cli-try-catch.wasm --entry=try-catch \
	--root=tests/programs tests/programs/try-catch.hx
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --output=out/wasm-cli-try-nested.wasm --entry=try-nested \
	--root=tests/programs tests/programs/try-nested.hx
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --output=out/wasm-cli-try-bounds.wasm --entry=try-array-bounds \
	--root=tests/programs tests/programs/try-array-bounds.hx
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
  ["out/wasm-backend-large-array.wasm", 20000],
  ["out/wasm-cli-backend.wasm", 42],
  ["out/wasm-cli-dynamic.wasm", 42],
  ["out/wasm-cli-type-test.wasm", 42],
  ["out/wasm-cli-array-slice.wasm", 42],
	["out/wasm-cli-array-mutation.wasm", 42],
	["out/wasm-cli-array-growth.wasm", 42],
	["out/wasm-cli-map-basic.wasm", 42],
	["out/wasm-cli-map-int.wasm", 42],
	["out/wasm-cli-map-primitive-types.wasm", 42],
	["out/wasm-cli-map-for-in.wasm", 52],
	["out/wasm-cli-map-key-value-for-in.wasm", 42],
	["out/wasm-cli-map-object.wasm", 42],
	["out/wasm-cli-map-anonymous-enum.wasm", 42],
	["out/wasm-cli-cnative-import.wasm", 42],
  ["out/wasm-cli-try-catch.wasm", 42],
  ["out/wasm-cli-try-nested.wasm", 42],
  ["out/wasm-cli-try-bounds.wasm", 42],
  ["out/wasm-backend-closure.wasm", 42],
  ["out/wasm-backend-instance-closure.wasm", 42],
  ["out/wasm-backend-virtual.wasm", 42]
];
(async () => {
  for (const [relative, expected] of cases) {
    const bytes = fs.readFileSync(`${root}/${relative}`);
    const imports = relative.endsWith("cnative-import.wasm")
      ? {fixture: {fixture_add: (left, right) => left + right}}
      : undefined;
    const {instance} = await WebAssembly.instantiate(bytes, imports);
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
