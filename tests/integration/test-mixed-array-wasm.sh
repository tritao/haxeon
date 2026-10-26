#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root_dir"
wasmtime=${WASMTIME:-$root_dir/.tools/wasmtime-47.0.0/wasmtime}
export LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$root_dir/.tools/haxe/haxe" -cp src -cp tests/compiler --run MixedArrayLiteralMain
node <<'JS'
const fs = require('fs');
const count = Number(fs.readFileSync('out/mixed-array-count.txt','utf8'));
for (let index=0; index<count; index++) {
 const bytes = fs.readFileSync(`out/mixed-array-Wasm32-${index}.wasm`);
 const result = new WebAssembly.Instance(new WebAssembly.Module(bytes),{}).exports.main();
 if (result !== 42) throw new Error(`mixed array ${index}: ${result}`);
}
console.log(`PASS: ${count} mixed array cases on Wasm32`);
JS
count=$(cat out/mixed-array-count.txt)
for ((index=0;index<count;index++)); do
 result=$("$wasmtime" run --invoke main "out/mixed-array-WasmGc-$index.wasm")
 test "$result" = 42
done
echo "PASS: $count mixed array cases on Wasm GC"
