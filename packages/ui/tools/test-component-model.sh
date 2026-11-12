#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ui="$root/packages/ui"
hl="$("$root/scripts/hashlink-path.sh")/hl"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-ui-component-model.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
compiler=${HAXEON_COMPILER_HL:-"$tmp/compiler.hl"}
if [[ ! -f "$compiler" ]]; then
    "$root/.tools/haxe/haxe" --cwd "$root" common.hxml -hl "$compiler" -main compiler.tools.HaxeonCompiler
fi
cat > "$tmp/memory.json" <<'JSON'
{"name":"nativekit-haxeon-linear-memory","version":1,"address_model":"wasm32","page_size":65536,"host_base":0,"host_limit":134217728,"guest_base":134217728,"guest_limit":268435456,"memory_size":268435456}
JSON
export LD_LIBRARY_PATH="$root/out:$("$root/scripts/hashlink-path.sh")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fixtures=("$@")
if [[ ${#fixtures[@]} == 0 ]]; then
  fixtures=(ScopeInstanceLifetimeMain ScopeCachedNestedLifetimeMain ScopeRootStateMain ScopeVariantRootMain ScopeNodeFieldsMain SelectionFocusMain MenuMeasurementMain IdSetMain StateStoreFlatMain ScopeRootBoundaryMain RenderScopeMain TrackedScopeMain EqualChildMain BoundTextMain BoundTextFailureMain BindingLifetimeMain TextIconMain IconButtonMain ButtonMain ScopeInputsMain FocusCaptureMain FocusDispatchAllocations)
fi
for fixture in "${fixtures[@]}"; do
  for inline in 0 1; do
    for target in hl wasm32 wasm-gc; do
        options=()
        platform_hxi="$root/packages/platform/bindings/nativekit.hxi"
        net_hxi="$root/packages/platform/bindings/nativekit-net.hxi"
        ui_hxi="$ui/bindings/nativekit-ui.hxi"
        if [[ $target != hl ]]; then
            options=(--target="$target" --wasm-import-memory --wasm-memory-contract="$tmp/memory.json")
            platform_hxi="$root/packages/platform/bindings/nativekit-wasm.hxi"
            net_hxi="$root/packages/platform/bindings/nativekit-net-wasm.hxi"
            ui_hxi="$ui/bindings/nativekit-ui-wasm.hxi"
        fi
        if [[ $fixture == FocusDispatchAllocations && $target != hl ]]; then
            options+=(--export=FocusDispatchCensus.prepare --export=FocusDispatchCensus.perform)
            if [[ $target == wasm32 ]]; then options+=(--wasm-memory-stats);
            else options+=(--wasm-gc-allocation-count); fi
        fi
        artifact="$tmp/$inline-$target"
        if ! HAXEON_INLINE="$inline" "$hl" "$compiler" "${options[@]}" --output="$artifact" \
                --entry=${fixture} --root="$ui/tests/haxeon" --root="${HAXEON_UI_SOURCE:-"$ui/haxe"}" \
                --root="$ui/bindings/haxe" --root="$root/packages/editor/src" --root="$root/packages/platform/src" \
                --ffi-interface="$platform_hxi" --ffi-projection="$root/packages/platform/bindings/nativekit.hxmap" \
                --ffi-interface="$net_hxi" --ffi-projection="$root/packages/platform/bindings/nativekit-net.hxmap" \
                --ffi-interface="$ui_hxi" --ffi-projection="$ui/bindings/nativekit-ui.hxmap" \
                "$ui/tests/haxeon/${fixture}.hx" > "$tmp/compile.log" 2>&1; then
            cat "$tmp/compile.log" >&2
            exit 1
        fi
        if [[ $target == hl ]]; then
            set +e
            "$hl" "$artifact"
            status=$?
            set -e
            if [[ $status != 42 ]]; then echo "FAIL: $target inline=$inline returned $status" >&2; exit 1; fi
        else
            node - "$artifact" "$target" "$inline" "$fixture" <<'JS'
const fs = require("fs");
(async () => {
  const [file, target, inline, fixture] = process.argv.slice(2);
  const module = new WebAssembly.Module(fs.readFileSync(file));
  const imports = {env: {memory: new WebAssembly.Memory({initial: 4096, maximum: 4096})}};
  class ExitSignal { constructor(code) { this.code = code; } }
  for (const entry of WebAssembly.Module.imports(module)) {
    if (entry.kind !== "function") continue;
    const group = imports[entry.module] ??= {};
    const mathName = entry.name.replace(/^__math_/, "");
    if (entry.module === "std" && entry.name === "sys_exit") {
      group[entry.name] = code => { throw new ExitSignal(code); };
    } else if (entry.module === "std" && entry.name === "sys_time") {
      group[entry.name] = () => 0;
    } else if (entry.module === "haxeon_runtime" && entry.name.startsWith("__math_") &&
        (mathName === "is_finite" || typeof Math[mathName] === "function")) {
      group[entry.name] = mathName === "is_finite" ? Number.isFinite : Math[mathName];
    } else {
      group[entry.name] = () => { throw new Error(`Unexpected host call: ${entry.module}.${entry.name}`); };
    }
  }
  const instance = await WebAssembly.instantiate(module, imports);
  let result;
  try { result = instance.exports.main(); }
  catch (error) { if (error instanceof ExitSignal) result = error.code; else throw error; }
  if (result !== 42) throw new Error(`${target} inline=${inline} returned ${result}`);
  if (fixture === "FocusDispatchAllocations") {
    const exports = instance.exports;
    exports["FocusDispatchCensus.prepare"]();
    exports["FocusDispatchCensus.perform"](8);
    const count = target === "wasm32" ? exports["haxeon.memory.allocation_count"] : exports.__allocation_count;
    for (const n of [8, 1024]) {
      const before = count();
      const delivered = exports["FocusDispatchCensus.perform"](n);
      const allocations = count() - before;
      if (delivered !== n * 6 || allocations !== 0)
        throw new Error(`focus/blur dispatch ${target} inline=${inline}: delivered=${delivered}, allocations=${allocations}`);
      console.log(`PASS: focus/blur dispatch on ${target}, inline=${inline}, n=${n}, allocations=0`);
    }
  }
})().catch(error => { console.error(error); process.exit(1); });
JS
        fi
        echo "PASS: $fixture on $target, inline=$inline"
    done
done
done
