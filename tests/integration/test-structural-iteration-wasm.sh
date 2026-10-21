#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root_dir"
wasmtime=${WASMTIME:-$root_dir/.tools/wasmtime-47.0.0/wasmtime}
export LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$root_dir/.tools/haxe/haxe" tests/hxml/structural-iteration-test.hxml
"$root_dir/.tools/hashlink/hl" out/structural-iteration-test.hl
node <<'JS'
const fs = require('fs');
for (const build of ['clean', 'incremental']) {
    const bytes = fs.readFileSync(`out/structural-iteration-Wasm32-${build}.wasm`);
    const actual = new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports.main();
    const expected = build === "clean" ? 42 : 43;
    if (actual !== expected) throw new Error(`wasm32 ${build}: ${actual}, expected ${expected}`);
}
JS
for build in clean incremental; do
    actual=$("$wasmtime" run --invoke main "out/structural-iteration-WasmGc-$build.wasm")
    expected=42
    if [[ $build == incremental ]]; then expected=43; fi
    if [[ $actual != "$expected" ]]; then
        echo "Structural iteration (Wasm GC, $build) returned $actual, expected $expected" >&2
        exit 1
    fi
done
echo "PASS: structural iteration on clean and incremental builds, Wasm linear and GC"
