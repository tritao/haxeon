#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root_dir"
wasmtime=${WASMTIME:-$root_dir/.tools/wasmtime-47.0.0/wasmtime}
export LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$root_dir/.tools/haxe/haxe" tests/hxml/wasm-dynamic-string-test.hxml
"$root_dir/.tools/hashlink/hl" out/wasm-dynamic-string-test.hl
node <<'JS'
const fs = require('fs');
for (const build of ['clean', 'incremental']) {
    for (const mode of ['Wasm32', 'Wasm32-stress']) {
        const bytes = fs.readFileSync(`out/dynamic-string-${mode}-${build}.wasm`);
        const module = new WebAssembly.Module(bytes);
        if (WebAssembly.Module.imports(module).length) throw new Error('Dynamic String support requires host imports');
        const actual = new WebAssembly.Instance(module, {}).exports.main();
        const expected = build === 'clean' ? 42 : 43;
        if (actual !== expected) throw new Error(`${mode} ${build}: ${actual}, expected ${expected}`);
    }
}
JS
for build in clean incremental; do
    actual=$("$wasmtime" run --invoke main "out/dynamic-string-WasmGc-$build.wasm")
    expected=42
    if [[ $build == incremental ]]; then expected=43; fi
    if [[ $actual != "$expected" ]]; then
        echo "Dynamic String (Wasm GC, $build) returned $actual, expected $expected" >&2
        exit 1
    fi
done
echo "PASS: dynamic String calls and callable errors on clean/incremental Wasm linear, stress GC and Wasm GC"
