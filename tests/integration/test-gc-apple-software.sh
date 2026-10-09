#!/usr/bin/env bash
set -euo pipefail
if [[ $(uname -s):$(uname -m) != Darwin:arm64 ]]; then
 echo 'SKIP: experimental Apple software GC requires a macOS arm64 runner'
 exit 0
fi
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-gc-apple.XXXXXX")
trap 'rm -rf "$work"' EXIT
library=${HL_GC_TEST_LIBRARY_DIR:-$root/.tools/hashlink}
vm=${HL_JIT_TEST_VM:-$root/.tools/hashlink/hl}
export DYLD_LIBRARY_PATH="$library:$root/out${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export HL_GC_INCREMENTAL_TEST_SOFTWARE=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_MIN_TRIGGER=65536
"${CC:-cc}" -I"$root/vendor/hashlink/src" "$root/tests/native/gc_incremental.c" -L"$library" -lhl -lpthread -o "$work/guards"
# A capability skip on this runner is a failure: the experimental build must
# explicitly support the selected validated test mode.
for threads in 1 4; do
 for repeat in 1 2 3; do
  HL_GC_THREADS=$threads "$work/guards"
  HL_GC_THREADS=$threads "$work/guards" pressure
 done
done
status=0
HL_GC_INCREMENTAL_VALIDATE=0 "$work/guards" >"$work/required.log" 2>&1 || status=$?
if [[ $status != 1 ]] || ! rg -q 'Test-only software GC requires HL_GC_INCREMENTAL_VALIDATE=1' "$work/required.log"; then
 cat "$work/required.log"
 echo 'FAIL: Apple test backend accepted disabled validation'
 exit 1
fi
mkdir -p "$work/stdlib/hl"
cp "$root/stdlib/hl/Gc.hx" "$work/stdlib/hl/Gc.hx"
for probe in FrameGcSchedulerProbe GcWriteBarrierProbe GcRuntimeWriteProbe; do
 "$root/.tools/haxe/haxe" -cp "$root/tests/native" -cp "$root/packages/ui/haxe" -cp "$work/stdlib" -hl "$work/$probe.hl" -main "$probe"
 for threads in 1 4; do HL_GC_THREADS=$threads "$vm" "$work/$probe.hl"; done
done
"${CC:-cc}" -dynamiclib "$root/tests/native/native_call_fixture.c" -lpthread -o "$work/fixture.dylib"
# HXI records here use LP64 layouts; target the runner's ABI explicitly.
export HAXEON_GC_BOUNDARY_TARGET=arm64-apple-darwin
for generator in HxiCallMain HxiRetainedMain; do
 (cd "$root"; HAXEON_GC_BOUNDARY_STRESS=1 "$root/.tools/haxe/haxe" -cp src -cp tests/runtime --run "$generator" "$work/$generator.hl" "$work/fixture.dylib")
 for threads in 1 4; do
  status=0
  HL_GC_THREADS=$threads "$vm" "$work/$generator.hl" || status=$?
  if [[ $status != 42 ]]; then echo "FAIL: Apple $generator returned $status"; exit 1; fi
 done
done
"$root/.tools/haxe/haxe" -cp "$root/src" -cp "$root/tests/runtime" -main GcModuleLifetimeMain -hl "$work/modules.hl"
for threads in 1 4; do HL_GC_THREADS=$threads "$vm" "$work/modules.hl"; done
echo 'PASS: experimental Apple AArch64 software GC validation suite'
