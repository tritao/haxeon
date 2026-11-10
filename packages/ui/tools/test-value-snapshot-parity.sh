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
entries=(local-snapshot host-lifecycle style-kinds cursor-shape layout-codes layout-policies text-codes widget-kinds presentation-kinds native-boundary-kinds)
negative_entries=(
    host-lifecycle-raw-int
    host-lifecycle-to-int
    style-kinds-raw-string
    style-kinds-to-string
    cursor-shape-raw-int
    cursor-shape-to-int
    layout-codes-sizing-raw-int
    layout-codes-sizing-to-int
    layout-codes-visual-raw-int
    layout-codes-visual-to-int
    layout-policies-direction-raw-int
    layout-policies-direction-to-int
    layout-policies-alignment-x-raw-int
    layout-policies-alignment-x-to-int
    layout-policies-alignment-y-raw-int
    layout-policies-alignment-y-to-int
    layout-policies-distribution-raw-int
    layout-policies-distribution-to-int
    layout-policies-positioning-raw-int
    layout-policies-positioning-to-int
    layout-policies-wrap-raw-int
    layout-policies-wrap-to-int
    layout-policies-self-alignment-raw-int
    layout-policies-self-alignment-to-int
    layout-policies-integer-property
    text-codes-font-family-raw-int
    text-codes-font-family-to-int
    text-codes-alignment-raw-int
    text-codes-alignment-to-int
    text-codes-wrap-raw-int
    text-codes-wrap-to-int
    text-codes-direction-raw-int
    text-codes-direction-to-int
    widget-kinds-button-variant-raw-int
    widget-kinds-button-variant-to-int
    widget-kinds-button-variant-raw-string
    widget-kinds-button-variant-to-string
    widget-kinds-spinner-kind-raw-int
    widget-kinds-spinner-kind-to-int
    widget-kinds-spinner-kind-raw-string
    widget-kinds-spinner-kind-to-string
    widget-kinds-progress-mode-raw-int
    widget-kinds-progress-mode-to-int
    widget-kinds-progress-mode-raw-string
    widget-kinds-progress-mode-to-string
    widget-kinds-image-fit-raw-int
    widget-kinds-image-fit-to-int
    widget-kinds-image-fit-raw-string
    widget-kinds-image-fit-to-string
    widget-kinds-split-side-raw-int
    widget-kinds-split-side-to-int
    widget-kinds-split-side-raw-string
    widget-kinds-split-side-to-string
    widget-kinds-split-orientation-raw-int
    widget-kinds-split-orientation-to-int
    widget-kinds-split-orientation-raw-string
    widget-kinds-split-orientation-to-string
    presentation-kinds-text-role-raw-int
    presentation-kinds-text-role-to-int
    presentation-kinds-text-role-raw-string
    presentation-kinds-text-role-to-string
    presentation-kinds-icon-name-raw-int
    presentation-kinds-icon-name-to-int
    presentation-kinds-icon-name-raw-string
    presentation-kinds-icon-name-to-string
    presentation-kinds-dock-panel-header-mode-raw-int
    presentation-kinds-dock-panel-header-mode-to-int
    presentation-kinds-dock-panel-header-mode-raw-string
    presentation-kinds-dock-panel-header-mode-to-string
    native-boundary-kinds-composite-mode-raw-int
    native-boundary-kinds-composite-mode-to-int
    native-boundary-kinds-composite-mode-raw-string
    native-boundary-kinds-composite-mode-to-string
    native-boundary-kinds-line-cap-raw-int
    native-boundary-kinds-line-cap-to-int
    native-boundary-kinds-line-cap-raw-string
    native-boundary-kinds-line-cap-to-string
    native-boundary-kinds-line-join-raw-int
    native-boundary-kinds-line-join-to-int
    native-boundary-kinds-line-join-raw-string
    native-boundary-kinds-line-join-to-string
    native-boundary-kinds-image-format-raw-int
    native-boundary-kinds-image-format-to-int
    native-boundary-kinds-image-format-raw-string
    native-boundary-kinds-image-format-to-string
    native-boundary-kinds-image-filter-raw-int
    native-boundary-kinds-image-filter-to-int
    native-boundary-kinds-image-filter-raw-string
    native-boundary-kinds-image-filter-to-string
    native-boundary-kinds-mask-kind-raw-int
    native-boundary-kinds-mask-kind-to-int
    native-boundary-kinds-mask-kind-raw-string
    native-boundary-kinds-mask-kind-to-string
    native-boundary-kinds-cache-policy-raw-int
    native-boundary-kinds-cache-policy-to-int
    native-boundary-kinds-cache-policy-raw-string
    native-boundary-kinds-cache-policy-to-string
    native-boundary-kinds-accessibility-role-raw-int
    native-boundary-kinds-accessibility-role-to-int
    native-boundary-kinds-accessibility-role-raw-string
    native-boundary-kinds-accessibility-role-to-string
    native-boundary-kinds-accessibility-orientation-raw-int
    native-boundary-kinds-accessibility-orientation-to-int
    native-boundary-kinds-accessibility-orientation-raw-string
    native-boundary-kinds-accessibility-orientation-to-string
    layout-codes-sizing-raw-string
    layout-codes-sizing-to-string
    layout-codes-visual-raw-string
    layout-codes-visual-to-string
    text-codes-font-family-raw-string
    text-codes-font-family-to-string
    text-codes-alignment-raw-string
    text-codes-alignment-to-string
    text-codes-wrap-raw-string
    text-codes-wrap-to-string
    text-codes-direction-raw-string
    text-codes-direction-to-string
)
if (( $# > 0 )); then
    for requested in "$@"; do
        found=0
        for entry in "${entries[@]}"; do
            if [[ "$requested" == "$entry" ]]; then found=1; fi
        done
        if [[ $found == 0 ]]; then echo "Unknown UI value fixture group: $requested" >&2; exit 2; fi
    done
    entries=("$@")
fi
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
        for entry in "${entries[@]}"; do
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
        for entry in "${negative_entries[@]}"; do
            if (( $# > 0 )); then
                selected=0
                for group in "${entries[@]}"; do
                    if [[ "$entry" == "$group-"* ]]; then selected=1; fi
                done
                if [[ $selected == 0 ]]; then continue; fi
            fi
            if HAXEON_INLINE="$inline" "$hl" "$compiler" "${options[@]}" --entry="$entry" \
                    --output="$tmp/rejected.$suffix" "${common[@]}" \
                    --ffi-interface="$platform_hxi" --ffi-projection="$root/packages/platform/bindings/nativekit.hxmap" \
                    --ffi-interface="$net_hxi" --ffi-projection="$root/packages/platform/bindings/nativekit-net.hxmap" \
                    --ffi-interface="$ui_hxi" --ffi-projection="$ui/bindings/nativekit-ui.hxmap" \
                    "$ui/tests/value-types/$entry.hx" > "$tmp/rejected.log" 2>&1; then
                echo "FAIL: $entry accepted an implicit raw-value conversion on $target, inline=$inline" >&2
                exit 1
            fi
            expected='E1002: Type mismatch for local "state"'
            rejection='implicit raw-value conversion'
            if [[ $entry == layout-policies-integer-property ]]; then
                expected='E1009: Type mismatch for argument 1 to "haxeon.ui.style.ComputedStyle.setInteger"'
                rejection='integer writes to an enum property'
            fi
            if ! grep -Fq "$expected" "$tmp/rejected.log"; then
                cat "$tmp/rejected.log" >&2
                exit 1
            fi
            echo "PASS: $entry rejects $rejection on $target, inline=$inline"
        done
    done
done
