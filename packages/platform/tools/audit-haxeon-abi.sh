#!/usr/bin/env bash
set -euo pipefail

package_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$package_dir/../.." && pwd)"}
nativekit_dir=${NATIVEKIT_DIR:-"$haxeon_dir/vendor/nativekit"}
platform_dir="$haxeon_dir/packages/platform"
gpu_dir="$haxeon_dir/packages/gpu"

# A relative --output names a path from where the script was run, not from the platform package it works in.
arguments=()
for argument in "$@"; do
    if [[ $argument == --output=* && ${argument#--output=} != /* ]]; then
        argument="--output=$PWD/${argument#--output=}"
    fi
    arguments+=("$argument")
done

cd "$platform_dir"

"$haxeon_dir/scripts/haxeon" ffi audit \
    --target=x86_64-linux-gnu \
    --target=x86_64-w64-windows-gnu \
    --target=x86_64-apple-darwin \
    --target=arm64-apple-darwin \
    --target=wasm32-unknown-wasi \
    --target=wasm32-unknown-emscripten \
    --profile=portable \
    --library=nativekit \
    --interface=NativeKit \
    --include="$nativekit_dir/include" \
    --source-label=bindings/haxe/nativekit_import.h \
    --exclude-header="$nativekit_dir/include/nativekit_net.h" \
    ${arguments[@]+"${arguments[@]}"} \
    "$platform_dir/bindings/nativekit_import.h"
