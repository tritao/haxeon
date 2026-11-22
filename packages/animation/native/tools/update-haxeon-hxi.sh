#!/usr/bin/env bash
set -euo pipefail

module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$module_dir/../../.." && pwd)"}
output="$module_dir/bindings/animkit.hxi"
destination=$output

if [[ ${1:-} == "--check" ]]; then
    destination=$(mktemp)
    trap 'rm -f -- "$destination"' EXIT
elif [[ $# -ne 0 ]]; then
    echo "usage: native/tools/update-haxeon-hxi.sh [--check]" >&2
    exit 2
fi

"$haxeon_dir/scripts/haxeon" ffi audit \
    --target=x86_64-linux-gnu \
    --target=x86_64-w64-windows-gnu \
    --target=x86_64-apple-darwin \
    --target=arm64-apple-darwin \
    --profile=portable-abi64 \
    --library=animkit_core \
    --interface=AnimKitNative \
    --include="$module_dir/include" \
    --source-label=native/bindings/animkit_import.h \
    --output="$destination" \
    "$module_dir/bindings/animkit_import.h"

if [[ ${1:-} == "--check" ]] && ! cmp -s "$output" "$destination"; then
    echo "Haxeon animation binding is stale; run native/tools/update-haxeon-hxi.sh" >&2
    diff -u "$output" "$destination" || true
    exit 1
fi
