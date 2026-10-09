#!/usr/bin/env bash
set -euo pipefail
if [[ $(uname -s) != Linux ]]; then
 echo 'SKIP: software GC boundary stress currently validates Linux only'
 exit 0
fi
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-gc-ffi.XXXXXX")
trap 'rm -rf "$work"' EXIT
library=${HL_GC_TEST_LIBRARY_DIR:-$root/.tools/hashlink}
vm=${HL_JIT_TEST_VM:-$root/.tools/hashlink/hl}
"${CC:-cc}" -shared -fPIC "$root/tests/native/gc_no_proc_tracking.c" -ldl -o "$work/no-proc.so"
"${CC:-cc}" -shared -fPIC "$root/tests/native/gc_drop_range.c" -ldl -o "$work/drop-range.so"
"${CC:-cc}" -shared -fPIC "$root/tests/native/native_call_fixture.c" -lpthread -o "$work/fixture.so"
"${CC:-cc}" -D_DEFAULT_SOURCE -I"$root/vendor/hashlink/src" "$root/tests/native/gc_ffi_roots.c" -L"$library" -L"$root/out" -Wl,--allow-shlib-undefined -l:haxeon_runtime.hdll -lhl -lpthread -ldl -o "$work/roots"
# The generators use the pinned compiler's complete standard library. The
# generated HXI program resolves Haxeon's GC extern from its source root.
(cd "$root"; HAXEON_GC_BOUNDARY_STRESS=1 "$root/.tools/haxe/haxe" -cp src -cp tests/runtime --run HxiCallMain "$work/hxi.hl" "$work/fixture.so")
(cd "$root"; HAXEON_GC_BOUNDARY_STRESS=1 "$root/.tools/haxe/haxe" -cp src -cp tests/runtime --run HxiRetainedMain "$work/borrowed.hl" "$work/fixture.so")
"$root/.tools/haxe/haxe" -cp "$root/src" -cp "$root/tests/runtime" -main GcModuleLifetimeMain -hl "$work/modules.hl"
export HL_GC_INCREMENTAL_TEST_SOFTWARE=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_MIN_TRIGGER=65536
export LD_LIBRARY_PATH="$library:$root/out${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_PRELOAD="$work/no-proc.so"
for threads in 1 4; do
 export HL_GC_THREADS=$threads
 for repeat in 1 2 3; do
  for mode in value closure; do
   args=(); [[ $mode == value ]] || args+=(closure)
   "$work/roots" "${args[@]}"
   HL_GC_TEST_AFTER_PREPARATION=1 "$work/roots" "${args[@]}"
  done
  status=0; "$vm" "$work/hxi.hl" || status=$?
  if [[ $status != 42 ]]; then echo "FAIL: HXI boundary stress returned $status"; exit 1; fi
  status=0; "$vm" "$work/borrowed.hl" || status=$?
  if [[ $status != 42 ]]; then echo "FAIL: borrowed HXI storage stress returned $status"; exit 1; fi
 done
 "$vm" "$work/modules.hl"
done
for mode in value closure; do
 args=(); [[ $mode == value ]] || args+=(closure)
 status=0
 HL_GC_TEST_AFTER_PREPARATION=1 HL_GC_THREADS=1 LD_PRELOAD="$work/no-proc.so:$work/drop-range.so" "$work/roots" "${args[@]}" >"$work/missing-$mode.log" 2>&1 || status=$?
 expected=1; [[ $mode == value ]] || expected=2
 if [[ $status != 1 ]] || ! rg -q "GC incremental validation failed: $expected reachable objects missing" "$work/missing-$mode.log"; then
  cat "$work/missing-$mode.log"
  echo "FAIL: targeted root-array barrier control ($mode)"
  exit 1
 fi
done
echo 'PASS: software-only FFI boundary stress and targeted value/closure barrier controls'
