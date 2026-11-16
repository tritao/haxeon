#!/usr/bin/env bash
set -euo pipefail

module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$module_dir/../.." && pwd)"}
repo_dir=${NATIVEKIT_DIR:-"$haxeon_dir/vendor/nativekit"}
platform_dir="$haxeon_dir/packages/platform"
output="$module_dir/bindings/nativekit-audio.hxi"
destination=$output

if [[ ${1:-} == "--check" ]]; then
    destination=$(mktemp)
    trap 'rm -f -- "$destination"' EXIT
elif [[ $# -ne 0 ]]; then
    echo "usage: tools/update-haxeon-hxi.sh [--check]" >&2
    exit 2
fi

"$haxeon_dir/scripts/haxeon-ffi-audit" \
    --target=x86_64-linux-gnu \
    --target=x86_64-w64-windows-gnu \
    --target=x86_64-apple-darwin \
    --target=arm64-apple-darwin \
    --profile=portable-abi64 \
    --library=nativekit \
    --interface=NativeKitAudio \
    --depends=NativeKit \
    --dependency-hxi="$platform_dir/bindings/nativekit.hxi" \
    --include="$repo_dir/modules/audio/include" \
    --include="$repo_dir/modules/audio/bindings" \
    --include="$repo_dir/include" \
    --exclude-header="$repo_dir/include/nativekit.h" \
    --exclude-header="$repo_dir/include/nativekit_resource.h" \
    --source-label=modules/audio/bindings/nativekit_audio_import.h \
    --output="$destination" \
    "$repo_dir/modules/audio/bindings/nativekit_audio_import.h"

if [[ ${1:-} == "--check" ]] && ! cmp -s "$output" "$destination"; then
    echo "Haxeon audio binding is stale; run tools/update-haxeon-hxi.sh" >&2
    diff -u "$output" "$destination" || true
    exit 1
fi
