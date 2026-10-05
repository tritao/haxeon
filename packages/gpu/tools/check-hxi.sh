#!/usr/bin/env bash
set -euo pipefail

package_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$package_dir/../.." && pwd)"}
nativekit_dir=${NATIVEKIT_DIR:-"$haxeon_dir/vendor/nativekit"}
platform_dir="$haxeon_dir/packages/platform"
gpu_dir="$haxeon_dir/packages/gpu"
output=${1:-"$gpu_dir/bindings/nativekit-gpu.hxi"}

"$haxeon_dir/scripts/haxeon-ffi-audit" \
    --target=x86_64-linux-gnu \
    --target=x86_64-w64-windows-gnu \
    --target=x86_64-apple-darwin \
    --target=arm64-apple-darwin \
    --profile=portable-abi64 \
    --library=nativekit_gpu \
    --interface=NativeKitGpu \
    --depends=NativeKit \
    --dependency-hxi="$platform_dir/bindings/nativekit.hxi" \
    --include="$nativekit_dir/modules/gpu/include" \
    --include="$gpu_dir/bindings" \
    --include="$nativekit_dir/include" \
    --exclude-header="$nativekit_dir/include/nativekit.h" \
    --exclude-header="$nativekit_dir/include/nativekit_graphics.h" \
    --source-label=modules/gpu/bindings/nativekit_gpu_import.h \
    --output="$output" \
    "$gpu_dir/bindings/nativekit_gpu_import.h"

echo "check-hxi: wrote $output"
