#!/usr/bin/env bash
set -euo pipefail

package_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$package_dir/../.." && pwd)"}
nativekit_dir=${NATIVEKIT_DIR:-"$haxeon_dir/vendor/nativekit"}
platform_dir="$haxeon_dir/packages/platform"
gpu_dir="$haxeon_dir/packages/gpu"
output="$platform_dir/bindings/nativekit-net.hxi"

if [[ $# -gt 1 ]]; then
    echo "usage: tools/update-haxeon-net-hxi.sh [--check | --output=PATH]" >&2
    exit 2
elif [[ ${1:-} == "--check" ]]; then
    destination=$(mktemp)
    trap 'rm -f -- "$destination"' EXIT
elif [[ ${1:-} == --output=?* ]]; then
    destination=${1#--output=}
elif [[ $# -ne 0 ]]; then
    echo "usage: tools/update-haxeon-net-hxi.sh [--check | --output=PATH]" >&2
    exit 2
else
    destination="$output"
fi

"$haxeon_dir/scripts/haxeon-ffi-audit" \
    --target=x86_64-linux-gnu \
    --target=x86_64-w64-windows-gnu \
    --target=x86_64-apple-darwin \
    --target=arm64-apple-darwin \
    --profile=portable-abi64 \
    --library=nativekit \
    --interface=NativeKitNet \
    --depends=NativeKit \
    --dependency-hxi="$platform_dir/bindings/nativekit.hxi" \
    --include="$nativekit_dir/include" \
    --exclude-header="$nativekit_dir/include/nativekit.h" \
    --source-label=bindings/haxe/nativekit_net_import.h \
    --output="$destination" \
    "$platform_dir/bindings/nativekit_net_import.h"

if [[ ${1:-} == "--check" ]] && ! cmp -s "$output" "$destination"; then
    echo "Haxeon net binding is stale; run tools/update-haxeon-net-hxi.sh" >&2
    diff -u "$output" "$destination" || true
    exit 1
fi

echo "update-haxeon-net-hxi: wrote $destination"
