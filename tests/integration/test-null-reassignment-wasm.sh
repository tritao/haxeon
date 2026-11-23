#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "$0")/../.." && pwd)
export HAXEON_SDK=${HAXEON_SDK:-$root_dir/out/sdk} # the Haxe test mains start the VM from it
cd "$root_dir"
wasmtime=${WASMTIME:-$root_dir/.tools/wasmtime-47.0.0/wasmtime}
export LD_LIBRARY_PATH="$root_dir/out:$("$root_dir/scripts/hashlink-path.sh")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
source "$root_dir/scripts/lib/env.sh"
out_dir=$haxeon_suite_out # where the test main writes (tests/SuiteOutput.hx) and this script reads
mkdir -p "$out_dir"
export out_dir
"$root_dir/.tools/haxe/haxe" common.hxml -cp tests -cp tests/compiler --run NullReassignmentMain
node <<'JS'
const fs = require('fs');
const count = Number(fs.readFileSync(`${process.env.out_dir}/null-reassignment-count.txt`,'utf8'));
for (let index=0; index<count; index++) {
 const bytes = fs.readFileSync(`${process.env.out_dir}/null-reassignment-Wasm32-${index}.wasm`);
 const result = new WebAssembly.Instance(new WebAssembly.Module(bytes),{}).exports.main();
 if (result !== 42) throw new Error(`null reassignment ${index}: ${result}`);
}
console.log(`PASS: ${count} null reassignment cases on Wasm32`);
JS
count=$(cat "$out_dir/null-reassignment-count.txt")
for ((index=0;index<count;index++)); do
 result=$("$wasmtime" run --invoke main "$out_dir/null-reassignment-WasmGc-$index.wasm")
 test "$result" = 42
done
echo "PASS: $count null reassignment cases on Wasm GC"
