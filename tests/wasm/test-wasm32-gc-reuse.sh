#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/../.." && pwd)
source "$root_dir/scripts/lib/env.sh"
out_dir=$haxeon_suite_out # this suite's own directory: every file it writes and reads back goes there
haxe_bin="$root_dir/.tools/haxe/haxe"
artifact="$out_dir/wasm-gc-reuse-zero-init.wasm"

haxeon_require_haxe
source "$root_dir/scripts/haxeon-compiler.sh"

mkdir -p "$out_dir"
haxeon_compile \
	--target=wasm32 --output="$artifact" --entry=wasm-gc-reuse \
	--wasm-gc-stress \
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
