#!/usr/bin/env bash
set -euo pipefail

module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$module_dir/../../.." && pwd)"}
output=${1:-"$module_dir/bindings/animkit.hxi"}

"$haxeon_dir/scripts/haxeon-ffi-audit" \
    --target=x86_64-linux-gnu \
    --target=x86_64-w64-windows-gnu \
    --target=x86_64-apple-darwin \
    --target=arm64-apple-darwin \
    --profile=portable-abi64 \
    --library=animkit_core \
    --interface=AnimKitNative \
    --include="$module_dir/include" \
    --source-label=native/bindings/animkit_import.h \
    --output="$output" \
    "$module_dir/bindings/animkit_import.h"

echo "check-hxi: wrote $output"
