#!/usr/bin/env bash
set -euo pipefail

package_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$package_dir/../.." && pwd)"}
nativekit_dir=${NATIVEKIT_DIR:-"$haxeon_dir/vendor/nativekit"}
platform_dir="$haxeon_dir/packages/platform"
gpu_dir="$haxeon_dir/packages/gpu"
profile=portable-abi64
targets=(--target=x86_64-linux-gnu --target=x86_64-w64-windows-gnu
    --target=x86_64-apple-darwin --target=arm64-apple-darwin)
suffix=
if [[ ${1:-} == "--wasm" ]]; then
    shift
    profile=portable-abi32
    targets=(--target=wasm32-unknown-wasi --target=wasm32-unknown-emscripten)
    suffix=-wasm
fi
output="$gpu_dir/bindings/nativekit-gpu$suffix.hxi"
destination=$output

if [[ ${1:-} == "--check" ]]; then
    destination=$(mktemp)
    trap 'rm -f -- "$destination"' EXIT
elif [[ $# -ne 0 ]]; then
    echo "usage: tools/update-haxeon-hxi.sh [--wasm] [--check]" >&2
    exit 2
fi

"$haxeon_dir/scripts/haxeon" ffi audit \
    "${targets[@]}" \
    --profile="$profile" \
    --library=nativekit_gpu \
    --interface=NativeKitGpu \
    --depends=NativeKit \
    --dependency-hxi="$platform_dir/bindings/nativekit$suffix.hxi" \
    --include="$nativekit_dir/modules/gpu/include" \
    --include="$gpu_dir/bindings" \
    --include="$nativekit_dir/include" \
    --exclude-header="$nativekit_dir/include/nativekit.h" \
    --exclude-header="$nativekit_dir/include/nativekit_graphics.h" \
    --source-label=modules/gpu/bindings/nativekit_gpu_import.h \
    --output="$destination" \
    "$gpu_dir/bindings/nativekit_gpu_import.h"

if [[ ${1:-} == "--check" ]] && ! cmp -s "$output" "$destination"; then
    echo "Haxeon GPU binding is stale; run tools/update-haxeon-hxi.sh" >&2
    diff -u "$output" "$destination" || true
    exit 1
fi
