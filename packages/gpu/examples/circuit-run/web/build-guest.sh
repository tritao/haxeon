#!/usr/bin/env bash
set -euo pipefail

example_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(cd "$example_dir/../../../.." && pwd)
nativekit=${NATIVEKIT_DIR:-"$root/vendor/nativekit"}
artifact=$1
contract=$2
gpu_schema=$(dirname "$artifact")/nativekit-gpu-wasm.hxi

"$root/scripts/haxeon" ffi audit \
    --target=wasm32-unknown-wasi --target=wasm32-unknown-emscripten --profile=portable-abi32 \
    --library=nativekit_gpu --interface=NativeKitGpu --depends=NativeKit \
    --dependency-hxi="$root/packages/platform/bindings/nativekit-wasm.hxi" \
    --include="$nativekit/modules/gpu/include" --include="$root/packages/gpu/bindings" \
    --include="$nativekit/include" --exclude-header="$nativekit/include/nativekit.h" \
    --exclude-header="$nativekit/include/nativekit_graphics.h" \
    --source-label=modules/gpu/bindings/nativekit_gpu_import.h --output="$gpu_schema" \
    "$root/packages/gpu/bindings/nativekit_gpu_import.h"

cd "$root"
"${NATIVEKIT_HAXE_BIN:-$root/.tools/haxe/haxe}" common.hxml --run compiler.tools.HaxeonCompiler \
    --target=wasm32 --define=circuit_run_web --entry=Main --output="$artifact" --wasm-import-memory \
    --wasm-memory-contract="$contract" --export=Main.main --export=Main.poll --export=Main.shutdown \
    --root="$example_dir/src" --root="$root/packages/platform/src" --root="$root/packages/gpu/src" \
    --root="$root/packages/audio/src" --root="$root/packages/editor/src" \
    --root="$root/packages/ui/haxe" --root="$root/packages/ui/bindings/haxe" \
    --ffi-interface="$root/packages/platform/bindings/nativekit-wasm.hxi" \
    --ffi-projection="$root/packages/platform/bindings/nativekit.hxmap" \
    --ffi-interface="$root/packages/platform/bindings/nativekit-net-wasm.hxi" \
    --ffi-projection="$root/packages/platform/bindings/nativekit-net.hxmap" \
    --ffi-interface="$gpu_schema" --ffi-projection="$root/packages/gpu/bindings/nativekit-gpu.hxmap" \
    --ffi-interface="$root/packages/audio/bindings/nativekit-audio-wasm.hxi" \
    --ffi-projection="$root/packages/audio/bindings/nativekit-audio.hxmap" \
    --ffi-interface="$root/packages/ui/bindings/nativekit-ui-wasm.hxi" \
    --ffi-projection="$root/packages/ui/bindings/nativekit-ui.hxmap" \
    "$example_dir/src/"*.hx
