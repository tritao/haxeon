#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ui="$root/packages/ui"
hl="$("$root/scripts/hashlink-path.sh")/hl"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-ui-state-lifecycle.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
compiler=${HAXEON_COMPILER_HL:-"$tmp/compiler.hl"}
if [[ ! -f "$compiler" ]]; then
    "$root/.tools/haxe/haxe" -cp "$root/src" -hl "$compiler" -main compiler.tools.HaxeonCompiler
fi
cat > "$tmp/memory.json" <<'JSON'
{"name":"nativekit-haxeon-linear-memory","version":1,"address_model":"wasm32","page_size":65536,"host_base":0,"host_limit":134217728,"guest_base":134217728,"guest_limit":268435456,"memory_size":268435456}
JSON
export LD_LIBRARY_PATH="$root/out:$("$root/scripts/hashlink-path.sh")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
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
        artifact="$tmp/$inline-$target"
        if ! HAXEON_INLINE="$inline" "$hl" "$compiler" "${options[@]}" --output="$artifact" \
                --entry=StateStoreLifecycleMain --root="$ui/tests/haxeon" --root="$ui/haxe" \
                --root="$ui/bindings/haxe" --root="$root/packages/editor/src" --root="$root/packages/platform/src" \
                --ffi-interface="$platform_hxi" --ffi-projection="$root/packages/platform/bindings/nativekit.hxmap" \
                --ffi-interface="$net_hxi" --ffi-projection="$root/packages/platform/bindings/nativekit-net.hxmap" \
                --ffi-interface="$ui_hxi" --ffi-projection="$ui/bindings/nativekit-ui.hxmap" \
                "$ui/tests/haxeon/StateStoreLifecycleMain.hx" > "$tmp/compile.log" 2>&1; then
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
            node - "$artifact" "$target" "$inline" <<'JS'
const fs = require("fs");
(async () => {
  const [file, target, inline] = process.argv.slice(2);
  const module = new WebAssembly.Module(fs.readFileSync(file));
  const imports = {env: {memory: new WebAssembly.Memory({initial: 4096, maximum: 4096})}};
  class ExitSignal { constructor(code) { this.code = code; } }
  for (const entry of WebAssembly.Module.imports(module)) {
    if (entry.kind !== "function") continue;
    const group = imports[entry.module] ??= {};
    const mathName = entry.name.replace(/^__math_/, "");
    if (entry.module === "std" && entry.name === "sys_exit") {
      group[entry.name] = code => { throw new ExitSignal(code); };
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
})().catch(error => { console.error(error); process.exit(1); });
JS
        fi
        echo "PASS: state lifecycle on $target, inline=$inline"
    done
done
