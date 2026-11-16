#!/usr/bin/env bash
set -euo pipefail

package_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$package_dir/../.." && pwd)"}
nativekit_dir=${NATIVEKIT_DIR:-"$haxeon_dir/vendor/nativekit"}
platform_dir="$haxeon_dir/packages/platform"
gpu_dir="$haxeon_dir/packages/gpu"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

if [[ ! -x "$haxeon_dir/.tools/haxe/haxe" ]]; then
    echo "test-haxe-bindings: missing Haxeon compiler: $haxeon_dir/.tools/haxe/haxe" >&2
    exit 2
fi

HAXEON_DIR="$haxeon_dir" "$platform_dir/tools/update-haxeon-hxi.sh" --check
HAXEON_DIR="$haxeon_dir" "$platform_dir/tools/update-haxeon-vulkan-hxi.sh" --check
HAXEON_DIR="$haxeon_dir" "$platform_dir/tools/update-haxeon-net-hxi.sh" --check
HAXEON_DIR="$haxeon_dir" "$platform_dir/tools/update-haxeon-wasm-hxi.sh" --check
HAXEON_DIR="$haxeon_dir" "$platform_dir/tools/update-haxeon-net-wasm-hxi.sh" --check

HAXEON_DIR="$haxeon_dir" "$gpu_dir/tools/update-haxeon-hxi.sh" --check

# No Wasm GPU binding is checked in, so the ABI32 run only audits that the GPU
# import header agrees across the Wasm targets; its output is discarded.
"$haxeon_dir/scripts/haxeon-ffi-audit" \
    --target=wasm32-unknown-wasi \
    --target=wasm32-unknown-emscripten \
    --profile=portable-abi32 \
    --library=nativekit_gpu \
    --interface=NativeKitGpu \
    --depends=NativeKit \
    --dependency-hxi="$platform_dir/bindings/nativekit-wasm.hxi" \
    --include="$nativekit_dir/modules/gpu/include" \
    --include="$gpu_dir/bindings" \
    --include="$nativekit_dir/include" \
    --exclude-header="$nativekit_dir/include/nativekit.h" \
    --exclude-header="$nativekit_dir/include/nativekit_graphics.h" \
    --source-label=modules/gpu/bindings/nativekit_gpu_import.h \
    --output="$test_root/nativekit-gpu-abi32.hxi" \
    "$gpu_dir/bindings/nativekit_gpu_import.h"

build_dir="$test_root/native-build"
cmake -S "$nativekit_dir" -B "$build_dir" -GNinja \
    -DCMAKE_BUILD_TYPE=Debug \
    -DNK_BUILD_SHARED=ON \
    -DNK_BUILD_GPU=ON \
    -DNK_BUILD_TESTS=ON \
    -DNK_BUILD_EXAMPLES=ON

HAXEON_DIR="$haxeon_dir" "$platform_dir/tools/test-haxeon.sh"
HAXEON_DIR="$haxeon_dir" NATIVEKIT_BUILD_DIR="$build_dir" \
    "$gpu_dir/tools/test-haxeon.sh"
echo "PASS: ABI32/ABI64 HXI drift checks and NativeKit core and GPU Haxeon smoke tests"
