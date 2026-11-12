#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ui="$root/packages/ui"
native=${NATIVEKIT_BUILD_DIR:-"$root/out/packages/ui/native"}
runtime=$("$root/scripts/hashlink-path.sh")
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-native-scope-feedback.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
cmake --build "$native" --target nativekit_ui
compiler=${HAXEON_COMPILER_HL:-"$work/compiler.hl"}
if [[ ! -f "$compiler" ]]; then
  "$root/.tools/haxe/haxe" --cwd "$root" common.hxml -hl "$compiler" -main compiler.tools.HaxeonCompiler
fi
export LD_LIBRARY_PATH="$native:$native/nativekit:$native/nativekit/modules/gpu:$root/out:$runtime${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export NKUI_TEST_FONT_PATH=${NKUI_TEST_FONT_PATH:-"$ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf"}
for inline in 0 1; do
  HAXEON_INLINE="$inline" "$runtime/hl" "$compiler" --output="$work/test.hl" \
    --entry=NativeScopeFeedbackMain --root="$ui/tests/haxeon" --root="$ui/haxe" \
    --root="$ui/bindings/haxe" --root="$root/packages/editor/src" --root="$root/packages/platform/src" \
    --ffi-interface="$root/packages/platform/bindings/nativekit.hxi" --ffi-projection="$root/packages/platform/bindings/nativekit.hxmap" \
    --ffi-interface="$root/packages/platform/bindings/nativekit-net.hxi" --ffi-projection="$root/packages/platform/bindings/nativekit-net.hxmap" \
    --ffi-interface="$ui/bindings/nativekit-ui.hxi" --ffi-projection="$ui/bindings/nativekit-ui.hxmap" \
    "$ui/tests/haxeon/NativeScopeFeedbackMain.hx" > "$work/compile.log" 2>&1 || {
      cat "$work/compile.log" >&2; exit 1;
    }
  status=0
  "$runtime/hl" "$work/test.hl" || status=$?
  if [[ $status != 42 ]]; then
    echo "FAIL: native scope feedback inline=$inline returned $status" >&2
    exit 1
  fi
  echo "PASS: native scope geometry feedback, inline=$inline"
done
