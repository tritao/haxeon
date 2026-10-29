#!/usr/bin/env bash
set -euo pipefail
module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$module_dir/../.." && pwd)"}
build_dir=${NATIVEKIT_BUILD_DIR:-"$haxeon_dir/out/packages/ui/native"}
project="$module_dir/tests/tooltip-content/haxeon.json"
# Native libraries are supplied by the enclosing NativeUI build, as in framework smoke.
export LD_LIBRARY_PATH="$build_dir:$(dirname "$build_dir"):$build_dir/nativekit/modules/gpu:$build_dir/nativekit:$haxeon_dir/out:$haxeon_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export DYLD_LIBRARY_PATH="$build_dir:$(dirname "$build_dir"):$haxeon_dir/out${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
"$haxeon_dir/scripts/haxeon" build --project "$project"
runner=("$haxeon_dir/.tools/hashlink/hl" "$module_dir/tests/tooltip-content/build/host/main.hl")
if command -v xvfb-run >/dev/null; then
    xvfb-run -a "${runner[@]}"
else
    "${runner[@]}"
fi
