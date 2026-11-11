#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ui="$root/packages/ui"
hl="$("$root/scripts/hashlink-path.sh")/hl"
work=$(mktemp -d "${TMPDIR:-$root/out}/haxeon-idle-parity.XXXXXXXX")
capture=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-idle-parity.XXXXXXXX")
trap 'rm -rf -- "$work" "$capture"' EXIT
compiler=${HAXEON_COMPILER_HL:-"$work/compiler.hl"}
if [[ ! -f "$compiler" ]]; then
  "$root/.tools/haxe/haxe" -cp "$root/src" -hl "$compiler" -main compiler.tools.HaxeonCompiler
fi
export LD_LIBRARY_PATH="$root/out:$("$root/scripts/hashlink-path.sh")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
for inline in 0 1; do
  for target in hl wasm32 wasm-gc; do
    suffix=; flags=()
    if [[ "$target" != hl ]]; then
      suffix=-wasm
      flags=(--wasm-import-memory --export=ComponentIdleParity.prepare --export=ComponentIdleParity.perform)
      if [[ "$target" == wasm32 ]]; then flags+=(--wasm-memory-stats --wasm-gc-stress)
      else flags+=(--wasm-gc-allocation-count); fi
    fi
    HAXEON_INLINE="$inline" "$hl" "$compiler" --target="$target" --output="$work/test" --entry=ComponentIdleParity \
      --root="$ui/tests/haxeon" --root="$ui/haxe" --root="$ui/bindings/haxe" \
      --root="$root/packages/editor/src" --root="$root/packages/platform/src" \
      --ffi-interface="$root/packages/platform/bindings/nativekit$suffix.hxi" --ffi-projection="$root/packages/platform/bindings/nativekit.hxmap" \
      --ffi-interface="$root/packages/platform/bindings/nativekit-net$suffix.hxi" --ffi-projection="$root/packages/platform/bindings/nativekit-net.hxmap" \
      --ffi-interface="$ui/bindings/nativekit-ui$suffix.hxi" --ffi-projection="$ui/bindings/nativekit-ui.hxmap" \
      "${flags[@]}" "$ui/tests/haxeon/ComponentIdleParity.hx" > "$capture/compile.log" 2>&1 || { cat "$capture/compile.log" >&2; exit 1; }
    if [[ "$target" == hl ]]; then
      for mode in 0 1 2; do
        set +e
        "$hl" "$work/test" "$mode" "$capture/census.json"
        status=$?
        set -e
        if [[ $status != 42 ]]; then echo "FAIL: HashLink mode=$mode inline=$inline exited $status" >&2; exit 1; fi
        python3 - "$capture/census.json" <<'PYTEST'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
assert data['allocations'] == 0, data['types']
PYTEST
      done
    else
      node - "$work/test" "$target" "$inline" <<'JS'
const fs = require('fs');
const [file, target, inline] = process.argv.slice(2);
const module = new WebAssembly.Module(fs.readFileSync(file));
const imports = {env: {memory: new WebAssembly.Memory({initial: 256})}};
for (const entry of WebAssembly.Module.imports(module)) {
  if (entry.kind !== 'function') continue;
  const group = imports[entry.module] ??= {};
  const mathName = entry.name.replace(/^__math_/, '');
  if (entry.module === 'std' && entry.name === 'sys_time') group[entry.name] = () => 0;
  else if (entry.module === 'haxeon_runtime' && entry.name.startsWith('__math_') &&
      (mathName === 'is_finite' || typeof Math[mathName] === 'function'))
    group[entry.name] = mathName === 'is_finite' ? Number.isFinite : Math[mathName];
  else group[entry.name] = () => { throw new Error(`Unexpected host call: ${entry.module}.${entry.name}`); };
}
const exports = new WebAssembly.Instance(module, imports).exports;
const count = target === 'wasm32' ? exports['haxeon.memory.allocation_count'] : exports.__allocation_count;
for (const mode of [0, 1, 2]) {
  exports['ComponentIdleParity.prepare'](mode);
  for (const n of [8, 1024]) {
    const before = count(), result = exports['ComponentIdleParity.perform'](n), allocated = count() - before;
    if (result !== n || allocated !== 0)
      throw new Error(`${target} mode=${mode} inline=${inline}: n=${n}, result=${result}, allocations=${allocated}`);
  }
}
JS
    fi
    echo "PASS: mounted component reuse allocates zero on $target, inline=$inline"
  done
done
