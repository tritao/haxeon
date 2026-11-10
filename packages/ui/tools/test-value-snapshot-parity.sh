#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ui="$root/packages/ui"
hl="$("$root/scripts/hashlink-path.sh")/hl"
haxe="$root/.tools/haxe/haxe"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-ui-value-parity.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
compiler=${HAXEON_COMPILER_HL:-"$tmp/compiler.hl"}
if [[ ! -f "$compiler" ]]; then
    "$haxe" -cp "$root/src" -hl "$compiler" -main compiler.tools.HaxeonCompiler
fi
cat > "$tmp/memory.json" <<'JSON'
{"name":"nativekit-haxeon-linear-memory","version":1,"address_model":"wasm32","page_size":65536,"host_base":0,"host_limit":134217728,"guest_base":134217728,"guest_limit":268435456,"memory_size":268435456}
JSON
export LD_LIBRARY_PATH="$root/out:$("$root/scripts/hashlink-path.sh"):$root/out/packages/ui/native${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
common=(--root="$ui/tests/value-types" --root="$ui/haxe"
    --root="$ui/bindings/haxe" --root="$root/packages/editor/src" --root="$root/packages/platform/src")
for inline in 0 1; do
    for target in hl wasm32 wasm-gc; do
        options=()
        suffix=hl
        if [[ $target == hl ]]; then
            platform_hxi="$root/packages/platform/bindings/nativekit.hxi"
            net_hxi="$root/packages/platform/bindings/nativekit-net.hxi"
            ui_hxi="$ui/bindings/nativekit-ui.hxi"
        else
            suffix=wasm
            options=(--target="$target" --wasm-import-memory --wasm-memory-contract="$tmp/memory.json")
            platform_hxi="$root/packages/platform/bindings/nativekit-wasm.hxi"
            net_hxi="$root/packages/platform/bindings/nativekit-net-wasm.hxi"
            ui_hxi="$ui/bindings/nativekit-ui-wasm.hxi"
        fi
        for entry in local-snapshot host-lifecycle style-kinds cursor-shape layout-codes; do
            artifact="$tmp/$entry-$inline-$target.$suffix"
            if ! HAXEON_INLINE="$inline" "$hl" "$compiler" "${options[@]}" --entry="$entry" --output="$artifact" "${common[@]}" \
                    --ffi-interface="$platform_hxi" --ffi-projection="$root/packages/platform/bindings/nativekit.hxmap" \
                    --ffi-interface="$net_hxi" --ffi-projection="$root/packages/platform/bindings/nativekit-net.hxmap" \
                    --ffi-interface="$ui_hxi" --ffi-projection="$ui/bindings/nativekit-ui.hxmap" \
                    "$ui/tests/value-types/$entry.hx" > "$tmp/compile.log" 2>&1; then
                cat "$tmp/compile.log" >&2
                exit 1
            fi
            if [[ $target == hl ]]; then
                set +e
                HAXEON_INLINE="$inline" "$hl" "$artifact"
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
  for (const entry of WebAssembly.Module.imports(module)) {
    if (entry.kind !== "function") continue;
    const group = imports[entry.module] ??= {};
    const mathName = entry.name.replace(/^__math_/, "");
    if (entry.module === "haxeon_runtime" && entry.name.startsWith("__math_") &&
        (mathName === "is_finite" || typeof Math[mathName] === "function")) {
      group[entry.name] = mathName === "is_finite" ? Number.isFinite : Math[mathName];
    } else {
      group[entry.name] = () => { throw new Error(`Unexpected host call: ${entry.module}.${entry.name}`); };
    }
  }
  const instance = await WebAssembly.instantiate(module, imports);
  const result = instance.exports.main();
  if (result !== 42) throw new Error(`${target} inline=${inline} returned ${result}`);
})().catch(error => { console.error(error); process.exitCode = 1; });
JS
            fi
            echo "PASS: $entry on $target, inline=$inline"
        done
        for entry in host-lifecycle-raw-int host-lifecycle-to-int style-kinds-raw-string style-kinds-to-string cursor-shape-raw-int cursor-shape-to-int layout-codes-sizing-raw-int layout-codes-sizing-to-int layout-codes-visual-raw-int layout-codes-visual-to-int; do
            if HAXEON_INLINE="$inline" "$hl" "$compiler" "${options[@]}" --entry="$entry" \
                    --output="$tmp/rejected.$suffix" "${common[@]}" \
                    "$ui/tests/value-types/$entry.hx" > "$tmp/rejected.log" 2>&1; then
                echo "FAIL: $entry accepted an implicit raw-value conversion on $target, inline=$inline" >&2
                exit 1
            fi
            if ! grep -Fq 'E1002: Type mismatch for local "state"' "$tmp/rejected.log"; then
                cat "$tmp/rejected.log" >&2
                exit 1
            fi
            echo "PASS: $entry rejects implicit raw-value conversion on $target, inline=$inline"
        done
    done
done
