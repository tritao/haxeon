#!/usr/bin/env bash
set -euo pipefail

package_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$package_dir/../.." && pwd)"}
nativekit_dir=${NATIVEKIT_DIR:-"$(dirname "$haxeon_dir")/nativekit"}
platform_dir="$haxeon_dir/packages/platform"
gpu_dir="$haxeon_dir/packages/gpu"
output="$platform_dir/bindings/nativekit-wasm.hxi"
destination=$output

if [[ ${1:-} == "--check" ]]; then
    destination=$(mktemp)
    trap 'rm -f -- "$destination"' EXIT
elif [[ $# -ne 0 ]]; then
    echo "usage: tools/update-haxeon-wasm-hxi.sh [--check]" >&2
    exit 2
fi

HAXEON_DIR="$haxeon_dir" "$haxeon_dir/scripts/haxeon-ffi-audit" \
    --target=wasm32-unknown-wasi \
    --target=wasm32-unknown-emscripten \
    --profile=portable-abi32 \
    --library=nativekit \
    --interface=NativeKit \
    --include="$nativekit_dir/include" \
    --source-label=bindings/haxe/nativekit_import.h \
    --output="$destination" \
    "$platform_dir/bindings/nativekit_import.h"

if [[ ${1:-} == "--check" ]] && ! cmp -s "$output" "$destination"; then
    echo "Haxeon wasm binding is stale; run tools/update-haxeon-wasm-hxi.sh" >&2
    diff -u "$output" "$destination" || true
    exit 1
fi
