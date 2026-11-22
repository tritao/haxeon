#!/usr/bin/env bash
set -euo pipefail

module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$module_dir/../.." && pwd)"}
materia_dir=${MATERIA_DIR:-"$(dirname "$haxeon_dir")"}
repo_dir=${NATIVEKIT_DIR:-"$haxeon_dir/vendor/nativekit"}
editor_dir=${HAXEON_EDITOR_DIR:-"$haxeon_dir/packages/editor"}
output="$module_dir/bindings/nativekit-ui.hxi"
destination=$output

if [[ ${1:-} == "--check" ]]; then
    destination=$(mktemp)
    trap 'rm -f -- "$destination"' EXIT
elif [[ $# -ne 0 ]]; then
    echo "usage: tools/update-haxeon-hxi.sh [--check]" >&2
    exit 2
fi

"$haxeon_dir/scripts/haxeon" ffi audit \
    --target=x86_64-linux-gnu \
    --target=x86_64-w64-windows-gnu \
    --target=x86_64-apple-darwin \
    --target=arm64-apple-darwin \
    --profile=portable-abi64 \
    --library=nativekit_ui \
    --interface=NativeKitUI \
    --depends=NativeKit \
    --dependency-hxi="$haxeon_dir/packages/platform/bindings/nativekit.hxi" \
    --include="$module_dir/include" \
    --include="$module_dir/bindings" \
    --include="$repo_dir/include" \
    --exclude-header="$repo_dir/include/nativekit.h" \
    --exclude-header="$repo_dir/include/nativekit_graphics.h" \
    --source-label=bindings/nativekit_ui_import.h \
    --output="$destination" \
    "$module_dir/bindings/nativekit_ui_import.h"

if [[ ${1:-} == "--check" ]] && ! cmp -s "$output" "$destination"; then
    echo "Haxeon UI binding is stale; run tools/update-haxeon-hxi.sh" >&2
    diff -u "$output" "$destination" || true
    exit 1
fi
