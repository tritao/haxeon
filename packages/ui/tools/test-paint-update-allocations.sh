#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"
tmp=$(mktemp -d "${TMPDIR:-$root/out}/haxeon-paint-census.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
compiler=${HAXEON_COMPILER_HL:-"$tmp/compiler.hl"}
if [[ ! -f "$compiler" ]]; then
  .tools/haxe/haxe -cp src -hl "$compiler" -main compiler.tools.HaxeonCompiler
fi
export LD_LIBRARY_PATH="$root/out:$("$root/scripts/hashlink-path.sh")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
roots=(--root=stdlib --root=packages/ui/haxe --root=packages/ui/bindings/haxe --root=packages/platform/src --root=packages/ui/tests/haxeon)
for inline in 0 1; do
  for target in hl wasm32 wasm-gc; do
    suffix=; [[ "$target" == hl ]] || suffix=-wasm
    ffi=(--ffi-interface="packages/platform/bindings/nativekit$suffix.hxi" --ffi-projection=packages/platform/bindings/nativekit.hxmap
      --ffi-interface="packages/platform/bindings/nativekit-net$suffix.hxi" --ffi-projection=packages/platform/bindings/nativekit-net.hxmap
      --ffi-interface="packages/ui/bindings/nativekit-ui$suffix.hxi" --ffi-projection=packages/ui/bindings/nativekit-ui.hxmap)
    flags=(); ext=hl
    if [[ "$target" == wasm32 ]]; then
      ext=wasm; flags=(--wasm-import-memory --wasm-memory-stats --wasm-gc-stress --export=PaintUpdateCensus.prepare --export=PaintUpdateCensus.perform --export=PaintUpdateCensus.cleanup)
    elif [[ "$target" == wasm-gc ]]; then
      ext=wasm; flags=(--wasm-import-memory --wasm-gc-allocation-count --export=PaintUpdateCensus.prepare --export=PaintUpdateCensus.perform --export=PaintUpdateCensus.cleanup)
    fi
    HAXEON_INLINE="$inline" scripts/hl "$compiler" --target="$target" --output="$tmp/test.$ext" --entry=PaintUpdateAllocations "${roots[@]}" "${ffi[@]}" "${flags[@]}" packages/ui/tests/haxeon/PaintUpdateAllocations.hx > "$tmp/compile.log" 2>&1 || { cat "$tmp/compile.log" >&2; exit 1; }
    if [[ "$target" == hl ]]; then
      set +e; scripts/hl "$tmp/test.hl"; status=$?; set -e
      [[ "$status" == 42 ]] || { echo "HashLink inline=$inline exited $status" >&2; exit 1; }
    else
      node - "$tmp/test.wasm" "$target" "$inline" <<'JS'
const fs = require('fs');
const [file, target, inline] = process.argv.slice(2);
const memory = new WebAssembly.Memory({initial: 256});
const live = new Set();
const imports = {env: {memory}, haxeon_runtime: {
  __math_is_finite: Number.isFinite,
  native_alloc: size => { const address = memory.buffer.byteLength; memory.grow(Math.ceil(size / 65536)); live.add(address); return address; },
  native_free: address => { if (!live.delete(address)) throw Error('invalid native free'); }
}};
const exports = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(file)), imports).exports;
const count = target === 'wasm32' ? exports['haxeon.memory.allocation_count'] : exports.__allocation_count;
exports['PaintUpdateCensus.prepare']();
exports['PaintUpdateCensus.perform'](1);
for (const n of [8, 1024]) {
  const before = count(), value = exports['PaintUpdateCensus.perform'](n), allocated = count() - before;
  if (value !== n || allocated !== 0) throw Error(`${target} inline=${inline} n=${n}: result=${value}, allocations=${allocated}`);
}
exports['PaintUpdateCensus.cleanup']();
if (live.size) throw Error(`${target} leaked ${live.size} blocks`);
JS
    fi
    echo "PASS: paint updates on $target, inline=$inline allocate nothing"
  done
done
