#!/usr/bin/env bash
set -euo pipefail

module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
haxeon_dir=${HAXEON_DIR:-"$(cd "$module_dir/../.." && pwd)"}
build_dir=${NATIVEKIT_BUILD_DIR:-"$haxeon_dir/out/packages/ui/native"}
export LD_LIBRARY_PATH="$build_dir:$build_dir/nativekit/modules/gpu:$build_dir/nativekit:$haxeon_dir/out:$haxeon_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export NKUI_TEST_FONT_PATH="${NKUI_TEST_FONT_PATH:-$module_dir/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf}"
exec "$haxeon_dir/scripts/haxeon" run --project "$module_dir/tests/combobox/haxeon.json"
