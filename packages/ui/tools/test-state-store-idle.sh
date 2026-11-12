#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ui="$root/packages/ui"
hl_dir=$("$root/scripts/hashlink-path.sh")
work=$(mktemp -d "${TMPDIR:-$root/out}/haxeon-state-idle.XXXXXXXX")
capture=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-state-idle.XXXXXXXX")
trap 'rm -rf -- "$work" "$capture"' EXIT
compiler=${HAXEON_COMPILER_HL:-"$work/compiler.hl"}
if [[ ! -f "$compiler" ]]; then
  "$root/.tools/haxe/haxe" -cp "$root/src" -hl "$compiler" -main compiler.tools.HaxeonCompiler
fi
export LD_LIBRARY_PATH="$root/out:$hl_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$hl_dir/hl" "$compiler" --target=hl --output="$work/test.hl" --entry=StateStoreIdleCensus \
  --root="$ui/tests/haxeon" --root="$ui/haxe" --root="$ui/bindings/haxe" \
  --root="$root/packages/editor/src" --root="$root/packages/platform/src" \
  --ffi-interface="$root/packages/platform/bindings/nativekit.hxi" --ffi-projection="$root/packages/platform/bindings/nativekit.hxmap" \
  --ffi-interface="$root/packages/platform/bindings/nativekit-net.hxi" --ffi-projection="$root/packages/platform/bindings/nativekit-net.hxmap" \
  --ffi-interface="$ui/bindings/nativekit-ui.hxi" --ffi-projection="$ui/bindings/nativekit-ui.hxmap" \
  "$ui/tests/haxeon/StateStoreIdleCensus.hx" > "$capture/compile.log" 2>&1 || { cat "$capture/compile.log" >&2; exit 1; }
set +e
"$hl_dir/hl" "$work/test.hl" "$capture/census.json"
status=$?
set -e
if [[ $status != 42 ]]; then echo "FAIL: idle state fixture exited $status" >&2; exit 1; fi
python3 - "$capture/census.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    census = json.load(f)
assert census['allocations'] == 0, census['types']
print('PASS: 100 unchanged state cleanup cycles allocate zero objects')
PY
