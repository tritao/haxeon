#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root_dir"
wasmtime=${WASMTIME:-$root_dir/.tools/wasmtime-47.0.0/wasmtime}
export LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$root_dir/.tools/haxe/haxe" -cp src -cp tests/compiler --run EnumTypedefConstructorMain
node <<'JS'
const fs = require('fs');
for (const build of ['clean','incremental','bound']) {
 const bytes = fs.readFileSync(`out/enum-typedef-Wasm32-${build}.wasm`);
 const result = new WebAssembly.Instance(new WebAssembly.Module(bytes),{}).exports.main();
 if (result !== 42) throw new Error(`${build}: ${result}`);
 console.log(`PASS Wasm32 enum alias ${build}: ${result}`);
}
JS
for build in clean incremental bound; do
 result=$("$wasmtime" run --invoke main "out/enum-typedef-WasmGc-$build.wasm")
 test "$result" = 42
 echo "PASS Wasm GC enum alias $build: $result"
done
