#!/usr/bin/env bash
# Compile the actual example entry points: fixture snapshots do not cover these callers.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ui="$root/packages/ui"
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-showcase-builds.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
compiler=${HAXEON_COMPILER_HL:-"$work/compiler.hl"}
hl="$("$root/scripts/hashlink-path.sh")/hl"
if [[ ! -f "$compiler" ]]; then
    "$root/.tools/haxe/haxe" --cwd "$root" common.hxml -main compiler.tools.HaxeonCompiler -hl "$compiler"
fi
export LD_LIBRARY_PATH="$root/out:$("$root/scripts/hashlink-path.sh")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cat > "$work/memory.json" <<'JSON'
{"name":"nativekit-haxeon-linear-memory","version":1,"address_model":"wasm32","page_size":65536,"host_base":0,"host_limit":134217728,"guest_base":134217728,"guest_limit":268435456,"memory_size":268435456}
JSON
cd "$root"
for target in hl wasm32 wasm-gc; do
    entry=ShowcaseDesktop
    suffix=
    options=(--target="$target")
    if [[ $target == hl ]]; then
        options+=(--ffi-interface="$root/packages/gpu/bindings/nativekit-gpu.hxi"
            --ffi-projection="$root/packages/gpu/bindings/nativekit-gpu.hxmap")
    fi
    if [[ $target != hl ]]; then
        suffix=-wasm
        entry=ShowcaseWeb
        [[ $target != wasm-gc ]] || entry=ShowcaseWebGcEntry
        options+=(--wasm-import-memory --wasm-memory-contract="$work/memory.json")
    fi
    compiler_env=()
    if [[ $target != hl ]]; then
        for symbol in main configure configureMode configureUiVisual configureBenchmark frame status diagnostic caretOffset caretAffinity caretDirection shutdown; do
            options+=(--export="ShowcaseWeb.$symbol")
        done
    fi
    [[ $target != wasm-gc ]] || compiler_env+=(HAXEON_WASM_LEGACY_EXCEPTIONS=1)
    artifact="$work/showcase-$target"
    if ! env "${compiler_env[@]}" "$hl" "$compiler" "${options[@]}" --entry="$entry" --output="$artifact" \
            --root="$ui/examples/ui_showcase" --root="$ui/haxe" --root="$ui/bindings/haxe" \
            --root="$root/packages/editor/src" --root="$root/packages/platform/src" --root="$root/packages/gpu/src" \
            --ffi-interface="$root/packages/platform/bindings/nativekit$suffix.hxi" \
            --ffi-projection="$root/packages/platform/bindings/nativekit.hxmap" \
            --ffi-interface="$root/packages/platform/bindings/nativekit-net$suffix.hxi" \
            --ffi-projection="$root/packages/platform/bindings/nativekit-net.hxmap" \
            --ffi-interface="$ui/bindings/nativekit-ui$suffix.hxi" --ffi-projection="$ui/bindings/nativekit-ui.hxmap" \
            --ffi-interface="$ui/bindings/nativekit-ui-showcase$suffix.hxi" \
            --ffi-projection="$ui/bindings/nativekit-ui-showcase.hxmap" \
            "$ui/examples/ui_showcase/$entry.hx" > "$work/$target.log" 2>&1; then
        cat "$work/$target.log" >&2
        exit 1
    fi
    if [[ $target != hl ]]; then
        node - "$artifact" <<'JS'
const fs = require("fs");
const wasmModule = new WebAssembly.Module(fs.readFileSync(process.argv[2]));
if (!WebAssembly.Module.exports(wasmModule).some(entry => entry.name === "main"))
  throw new Error("Showcase guest has no main export");
JS
    fi
    echo "PASS: Showcase builds on $target ($entry)"
done
