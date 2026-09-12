#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe_bin="$root_dir/.tools/haxe/haxe"
artifact="$root_dir/out/wasm-gc-reuse-zero-init.wasm"

if [[ ! -x "$haxe_bin" ]]; then
	echo "missing pinned Haxe; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

mkdir -p "$root_dir/out"
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --output="$artifact" --entry=wasm-gc-reuse \
	--root=tests/programs tests/programs/wasm-gc-reuse.hx

node - "$artifact" <<'JS'
const fs = require("fs");
const artifact = process.argv[2];
(async () => {
  const bytes = fs.readFileSync(artifact);
  const {instance} = await WebAssembly.instantiate(bytes, {});
  const result = instance.exports.main();
  if (result !== 42)
    throw new Error(`expected 42 after GC block reuse, got ${result}`);
  console.log("PASS: Wasm GC-reused allocations restore zero-default values");
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
JS
