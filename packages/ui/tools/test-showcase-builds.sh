#!/usr/bin/env bash
# Compile the actual example entry points: fixture snapshots do not cover these callers.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ui="$root/packages/ui"
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-showcase-builds.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
compiler=${HAXEON_COMPILER_HL:-$("$root/scripts/haxeon" dev tool-path compiler.tools.HaxeonCompiler)}
hl="$("$root/scripts/hashlink-path.sh")/hl"
export LD_LIBRARY_PATH="$root/out:$("$root/scripts/hashlink-path.sh")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cat > "$work/memory.json" <<'JSON'
{"name":"nativekit-haxeon-linear-memory","version":1,"address_model":"wasm32","page_size":65536,"host_base":0,"host_limit":134217728,"guest_base":134217728,"guest_limit":268435456,"memory_size":268435456}
JSON
cd "$root"
for target in hl wasm32 wasm-gc; do
    entry=ShowcaseDesktop
    options=(--target="$target" --ffi-interface="$root/packages/gpu/bindings/nativekit-gpu.hxi"
        --ffi-projection="$root/packages/gpu/bindings/nativekit-gpu.hxmap")
    if [[ $target != hl ]]; then
        entry=ShowcaseWeb
        options+=(--wasm-import-memory --wasm-memory-contract="$work/memory.json"
            --ffi-interface="$ui/bindings/nativekit-ui-browser.hxi")
        for symbol in configure caretOffset caretAffinity caretDirection; do
            options+=(--export="ShowcaseWeb.$symbol")
        done
        for symbol in tick step stop; do
            options+=(--export="haxeon.platform.BrowserHost.$symbol")
        done
    fi
    [[ $target != wasm-gc ]] || options+=(--wasm-legacy-exceptions)
    artifact="$work/showcase-$target"
    if ! "$hl" "$compiler" "${options[@]}" --entry="$entry" --output="$artifact" \
            --root="$ui/examples/ui_showcase" --root="$ui/src" \
            --root="$root/packages/editor/src" --root="$root/packages/platform/src" --root="$root/packages/gpu/src" \
            --ffi-interface="$root/packages/platform/bindings/nativekit.hxi" \
            --ffi-projection="$root/packages/platform/bindings/nativekit.hxmap" \
            --ffi-interface="$root/packages/platform/bindings/nativekit-net.hxi" \
            --ffi-projection="$root/packages/platform/bindings/nativekit-net.hxmap" \
            --ffi-interface="$ui/bindings/nativekit-ui.hxi" --ffi-projection="$ui/bindings/nativekit-ui.hxmap" \
            --ffi-interface="$ui/bindings/nativekit-ui-showcase.hxi" \
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
