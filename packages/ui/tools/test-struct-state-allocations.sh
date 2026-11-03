#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"
tmp=$(mktemp -d /dev/shm/haxeon-state-census.XXXXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
compiler=${HAXEON_COMPILER_HL:-"$tmp/compiler.hl"}
if [[ ! -f "$compiler" ]]; then
  .tools/haxe/haxe -cp src -hl "$compiler" -main compiler.tools.HaxeonCompiler
fi
export LD_LIBRARY_PATH="$root/out:$root/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
source_file=packages/ui/tests/haxeon/StructStateAllocations.hx
roots=(--root=stdlib --root=packages/ui/haxe --root=packages/ui/bindings/haxe --root=packages/platform/src --root=packages/editor/src --root=packages/ui/tests/haxeon)
for inline in 0 1; do
  for target in hl wasm32 wasm-gc; do
    suffix=; [[ "$target" == hl ]] || suffix=-wasm
    ffi=(--ffi-interface="packages/platform/bindings/nativekit$suffix.hxi" --ffi-projection=packages/platform/bindings/nativekit.hxmap
      --ffi-interface="packages/platform/bindings/nativekit-net$suffix.hxi" --ffi-projection=packages/platform/bindings/nativekit-net.hxmap
      --ffi-interface="packages/ui/bindings/nativekit-ui$suffix.hxi" --ffi-projection=packages/ui/bindings/nativekit-ui.hxmap)
    flags=(); ext=hl
    if [[ "$target" == wasm32 ]]; then
      ext=wasm; flags=(--wasm-import-memory --wasm-memory-stats --wasm-gc-stress --export=StateAllocationCensus.prepare --export=StateAllocationCensus.perform)
    elif [[ "$target" == wasm-gc ]]; then
      ext=wasm; flags=(--wasm-import-memory --wasm-gc-allocation-count --export=StateAllocationCensus.prepare --export=StateAllocationCensus.perform)
    fi
    HAXEON_INLINE="$inline" .tools/hashlink/hl "$compiler" --target="$target" --output="$tmp/test.$ext" --entry=StructStateAllocations "${roots[@]}" "${ffi[@]}" "${flags[@]}" "$source_file" > "$tmp/compile.log" 2>&1 || { cat "$tmp/compile.log" >&2; exit 1; }
    if [[ "$target" == hl ]]; then
      set +e; .tools/hashlink/hl "$tmp/test.hl"; status=$?; set -e
      [[ "$status" == 42 ]] || { echo "HashLink inline=$inline exited $status" >&2; exit 1; }
    else
      node - "$tmp/test.wasm" "$target" "$inline" <<'JS'
const fs = require('fs');
const [file, target, inline] = process.argv.slice(2);
const imports = {env: {memory: new WebAssembly.Memory({initial: 256})}, haxeon_runtime: {__math_is_finite: Number.isFinite}};
const exports = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(file)), imports).exports;
exports['StateAllocationCensus.prepare']();
const count = target === 'wasm32' ? exports['haxeon.memory.allocation_count'] : exports.__allocation_count;
for (const n of [8, 1024]) {
  const before = count(), value = exports['StateAllocationCensus.perform'](n), allocated = count() - before;
  if (value !== n * (n - 1) / 2 || allocated !== 0) throw new Error(`${target} inline=${inline} n=${n}: result=${value}, allocations=${allocated}`);
}
JS
    fi
    echo "PASS: State<struct> allocations on $target, inline=$inline"
  done
done
