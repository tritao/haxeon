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
roots=(--root=stdlib --root=packages/ui/haxe --root=packages/ui/bindings/haxe --root=packages/platform/src --root=packages/editor/src --root=packages/ui/tests/haxeon)
for fixture in state pointer; do
  if [[ "$fixture" == state ]]; then entry=StructStateAllocations; census=StateAllocationCensus; else entry=PointerLocationAllocations; census=PointerAllocationCensus; fi
  source_file="packages/ui/tests/haxeon/$entry.hx"
for inline in 0 1; do
  for target in hl wasm32 wasm-gc; do
    suffix=; [[ "$target" == hl ]] || suffix=-wasm
    ffi=(--ffi-interface="packages/platform/bindings/nativekit$suffix.hxi" --ffi-projection=packages/platform/bindings/nativekit.hxmap
      --ffi-interface="packages/platform/bindings/nativekit-net$suffix.hxi" --ffi-projection=packages/platform/bindings/nativekit-net.hxmap
      --ffi-interface="packages/ui/bindings/nativekit-ui$suffix.hxi" --ffi-projection=packages/ui/bindings/nativekit-ui.hxmap)
    flags=(); ext=hl
    if [[ "$target" == wasm32 ]]; then
      ext=wasm; flags=(--wasm-import-memory --wasm-memory-stats --wasm-gc-stress --export="$census.prepare" --export="$census.perform")
    elif [[ "$target" == wasm-gc ]]; then
      ext=wasm; flags=(--wasm-import-memory --wasm-gc-allocation-count --export="$census.prepare" --export="$census.perform")
    fi
    HAXEON_INLINE="$inline" .tools/hashlink/hl "$compiler" --target="$target" --output="$tmp/test.$ext" --entry="$entry" "${roots[@]}" "${ffi[@]}" "${flags[@]}" "$source_file" > "$tmp/compile.log" 2>&1 || { cat "$tmp/compile.log" >&2; exit 1; }
    if [[ "$target" == hl ]]; then
      set +e; .tools/hashlink/hl "$tmp/test.hl"; status=$?; set -e
      [[ "$status" == 42 ]] || { echo "HashLink inline=$inline exited $status" >&2; exit 1; }
    else
      node - "$tmp/test.wasm" "$target" "$inline" "$fixture" "$census" <<'JS'
const fs = require('fs');
const [file, target, inline, fixture, census] = process.argv.slice(2);
const imports = {std: {sys_time: () => 0}, env: {memory: new WebAssembly.Memory({initial: 256})}, haxeon_runtime: {__math_is_finite: Number.isFinite}};
const exports = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(file)), imports).exports;
const count = target === 'wasm32' ? exports['haxeon.memory.allocation_count'] : exports.__allocation_count;
const setupBefore = count();
exports[`${census}.prepare`]();
const setupAllocated = count() - setupBefore;
if (fixture === 'pointer' && target === 'wasm-gc' && setupAllocated > 78)
  throw new Error(`pointer setup exceeds the class control: ${setupAllocated} allocations`);
for (const n of [8, 1024]) {
  const before = count(), value = exports[`${census}.perform`](n), allocated = count() - before;
  if (value !== (fixture === 'state' ? n * (n - 1) / 2 : n) || allocated !== 0) throw new Error(`${target} inline=${inline} n=${n}: result=${value}, allocations=${allocated}`);
}
JS
    fi
    echo "PASS: $fixture struct allocations on $target, inline=$inline"
  done
done
done

# Root replacement snapshots IDs, then skips pointers cancelled by an earlier callback.
HAXEON_INLINE=0 .tools/hashlink/hl "$compiler" --target=hl --output="$tmp/pointer-behavior.hl" \
  --entry=PointerLocationBehavior "${roots[@]}" \
  --ffi-interface=packages/platform/bindings/nativekit.hxi --ffi-projection=packages/platform/bindings/nativekit.hxmap \
  --ffi-interface=packages/platform/bindings/nativekit-net.hxi --ffi-projection=packages/platform/bindings/nativekit-net.hxmap \
  --ffi-interface=packages/ui/bindings/nativekit-ui.hxi --ffi-projection=packages/ui/bindings/nativekit-ui.hxmap \
  packages/ui/tests/haxeon/PointerLocationBehavior.hx > "$tmp/compile.log" 2>&1 || { cat "$tmp/compile.log" >&2; exit 1; }
set +e; .tools/hashlink/hl "$tmp/pointer-behavior.hl"; status=$?; set -e
[[ "$status" == 42 ]] || { echo "Pointer behavior exited $status" >&2; exit 1; }
echo "PASS: pointer locations honor cancellation during root replacement"
