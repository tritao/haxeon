#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ui="$root/packages/ui"
native=${NATIVEKIT_BUILD_DIR:-"$root/out/packages/ui/native"}
hl="$("$root/scripts/hashlink-path.sh")/hl"
work=$(mktemp -d "${TMPDIR:-$root/out}/haxeon-idle-metrics.XXXXXXXX")
capture=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-idle-metrics.XXXXXXXX")
trap 'rm -rf -- "$work" "$capture"' EXIT
cmake --build "$native" --target nativekit_ui
compiler=${HAXEON_COMPILER_HL:-"$work/compiler.hl"}
if [[ ! -f "$compiler" ]]; then
  "$root/.tools/haxe/haxe" -cp "$root/src" -hl "$compiler" -main compiler.tools.HaxeonCompiler
fi
export LD_LIBRARY_PATH="$native:$native/nativekit/modules/gpu:$native/nativekit:$root/out:$("$root/scripts/hashlink-path.sh")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$hl" "$compiler" --output="$work/test.hl" --entry=IdleMetricsMain \
  --root="$ui/tests/haxeon" --root="$ui/haxe" --root="$ui/bindings/haxe" \
  --root="$root/packages/editor/src" --root="$root/packages/platform/src" \
  --ffi-interface="$root/packages/platform/bindings/nativekit.hxi" --ffi-projection="$root/packages/platform/bindings/nativekit.hxmap" \
  --ffi-interface="$root/packages/platform/bindings/nativekit-net.hxi" --ffi-projection="$root/packages/platform/bindings/nativekit-net.hxmap" \
  --ffi-interface="$ui/bindings/nativekit-ui.hxi" --ffi-projection="$ui/bindings/nativekit-ui.hxmap" \
  "$ui/tests/haxeon/IdleMetricsMain.hx" > "$capture/compile.log" 2>&1 || { cat "$capture/compile.log" >&2; exit 1; }
set +e
NKUI_TEST_FONT_PATH="$ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf" "$hl" "$work/test.hl" "$capture/census.json"
status=$?
set -e
if [[ $status != 42 ]]; then echo "FAIL: idle metrics fixture exited $status" >&2; exit 1; fi
python3 - "$capture/census.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
assert data['allocations'] == 0, data['types']
print('PASS: unchanged cached UI submission allocates zero objects; metrics retain snapshot semantics')
PY
