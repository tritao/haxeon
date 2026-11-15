#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "$0")/../.." && pwd)
export HAXEON_HASHLINK_DIR=${HAXEON_HASHLINK_DIR:-$("$root_dir/scripts/hashlink-path.sh")} # the Haxe test mains start the VM from it
cd "$root_dir"
wasmtime=${WASMTIME:-$root_dir/.tools/wasmtime-47.0.0/wasmtime}
export LD_LIBRARY_PATH="$root_dir/out:$("$root_dir/scripts/hashlink-path.sh")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
source "$root_dir/scripts/lib/env.sh"
out_dir=$haxeon_suite_out # where the test main writes (tests/SuiteOutput.hx) and this script reads
mkdir -p "$out_dir"
export out_dir
"$root_dir/.tools/haxe/haxe" tests/hxml/static-init-order-test.hxml -hl "$out_dir/static-init-order-test.hl"
"$("$root_dir/scripts/hashlink-path.sh")/hl" "$out_dir/static-init-order-test.hl"
node <<'JS'
const fs = require("fs");
for (const [build, expected] of [["clean", 2], ["incremental", 3]]) {
    const bytes = fs.readFileSync(`${process.env.out_dir}/static-init-Wasm32-${build}.wasm`);
    const actual = new WebAssembly.Instance(new WebAssembly.Module(bytes), {}).exports.main();
    if (actual !== expected) throw new Error(`wasm32 ${build}: ${actual}, expected ${expected}`);
}
JS
for build in clean incremental; do
    expected=2
    if [[ $build == incremental ]]; then expected=3; fi
    actual=$("$wasmtime" run --invoke main "$out_dir/static-init-WasmGc-$build.wasm")
    if [[ $actual != "$expected" ]]; then
        echo "Static initialization (Wasm GC, $build) returned $actual, expected $expected" >&2
        exit 1
    fi
done
echo "PASS: static initialization on clean and incremental builds, Wasm linear and GC"
