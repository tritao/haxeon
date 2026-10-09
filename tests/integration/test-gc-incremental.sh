#!/usr/bin/env bash
set -euo pipefail
# Existing failure tests exercise the production Linux backend explicitly.
export HL_GC_INCREMENTAL_TEST_SOFTWARE=0
if [[ $(uname -s) != Linux ]]; then
 echo 'SKIP: incremental dirty-page collector requires Linux'
 exit 0
fi
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-gc-incremental.XXXXXX")
trap 'rm -rf "$work"' EXIT
library=${HL_GC_TEST_LIBRARY_DIR:-$root/.tools/hashlink}
"${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror "$root/tests/native/gc_apple_tracking_probe.c" -lpthread -o "$work/apple-backend"
"$work/apple-backend"
"${CC:-cc}" -D_DEFAULT_SOURCE -I"$root/vendor/hashlink/src" "$root/tests/native/gc_incremental.c" -L"$library" -lhl -lpthread -o "$work/guards"
"${CC:-cc}" -shared -fPIC "$root/tests/native/gc_mask_soft_dirty.c" -ldl -o "$work/mask.so"
"${CC:-cc}" -shared -fPIC -DGC_TEST_DROP_BARRIERS "$root/tests/native/gc_mask_soft_dirty.c" -ldl -o "$work/drop.so"
"${CC:-cc}" -D_DEFAULT_SOURCE -I"$root/vendor/hashlink/src" "$root/tests/native/gc_dirty_slices.c" -L"$library" -lhl -lpthread -ldl -o "$work/dirty-slices"
"${CC:-cc}" -shared -fPIC "$root/tests/native/gc_watch_dirty.c" -ldl -o "$work/watch-dirty.so"
"${CC:-cc}" -D_DEFAULT_SOURCE -Wall -Wextra -Werror -I"$root/vendor/hashlink/src" "$root/tests/native/gc_dirty_batch.c" -L"$library" -lhl -lpthread -ldl -o "$work/dirty-batch"
"${CC:-cc}" -D_DEFAULT_SOURCE -Wall -Wextra -Werror -I"$root/vendor/hashlink/src" "$root/tests/native/gc_block_sizes.c" -L"$library" -lhl -lpthread -o "$work/block-sizes"
kernel_available=1
for threads in 1 4; do
 for failure in none pagemap clear_refs pressure; do
  args=()
  [[ $failure == none ]] || args+=("$failure")
  status=0
  HL_GC_MIN_TRIGGER=65536 HL_GC_THREADS=$threads LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/guards" "${args[@]}" || status=$?
  if [[ $status == 77 ]]; then kernel_available=0; break 2; fi
  [[ $status == 0 ]] || exit "$status"
 done
done
# Hide kernel dirty bits after capability probing to exercise software recording.
if [[ $kernel_available == 1 ]]; then
for threads in 1 4; do
 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_THREADS=$threads LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/block-sizes"
 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_THREADS=$threads LD_PRELOAD="$work/watch-dirty.so" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/dirty-batch"
 HL_GC_TEST_CANCEL_DIRTY=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_THREADS=$threads LD_PRELOAD="$work/watch-dirty.so" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/dirty-batch"
 HL_GC_TEST_UNBARRIERED_REDIRTY=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_THREADS=$threads LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/dirty-slices" software
 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_THREADS=$threads LD_PRELOAD="$work/watch-dirty.so" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/dirty-slices"
 HL_GC_TEST_CANCEL_DIRTY=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_THREADS=$threads LD_PRELOAD="$work/watch-dirty.so" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/dirty-slices"
done
for threads in 1 4; do
 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_MIN_TRIGGER=65536 HL_GC_THREADS=$threads LD_PRELOAD="$work/mask.so" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/guards"
done
status=0
HL_GC_RETENTION_PROFILE=0 HL_GC_INCREMENTAL_VALIDATE=0 HL_GC_MIN_TRIGGER=65536 HL_GC_THREADS=1 LD_PRELOAD="$work/drop.so" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/guards" || status=$?
if [[ $status != 7 ]]; then
 echo "FAIL: missing-barrier negative control returned $status, expected 7"
 exit 1
fi
echo 'PASS: missing-barrier negative control detected lost references'
status=0
HL_GC_TEST_HIDE_WATCHED_REVISITS=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_THREADS=1 LD_PRELOAD="$work/watch-dirty.so" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/dirty-slices" >"$work/capture-missing.log" 2>&1 || status=$?
if [[ $status != 1 ]] || ! rg -q 'GC incremental validation failed: 1 reachable objects missing' "$work/capture-missing.log"; then
 cat "$work/capture-missing.log"
 echo 'FAIL: partial kernel capture revisit negative control'
 exit 1
fi
echo 'PASS: hiding the final kernel revisit detects the lost reference'
status=0
HL_GC_TEST_HIDE_WATCHED_REVISITS=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_THREADS=1 LD_PRELOAD="$work/watch-dirty.so" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/dirty-batch" >"$work/batch-missing.log" 2>&1 || status=$?
if [[ $status != 1 ]] || ! rg -q 'GC incremental validation failed: 1 reachable objects missing' "$work/batch-missing.log"; then
 cat "$work/batch-missing.log"
 echo 'FAIL: captured-array cursor kernel revisit negative control'
 exit 1
fi
echo 'PASS: hiding the kernel revisit loses the write behind the suspended array cursor'


status=0
HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_MIN_TRIGGER=65536 HL_GC_THREADS=1 LD_PRELOAD="$work/drop.so" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/guards" >"$work/validation.log" 2>&1 || status=$?
if [[ $status != 1 ]] || ! rg -q 'GC incremental validation failed: [1-9][0-9]* reachable objects missing' "$work/validation.log"; then
 cat "$work/validation.log"
 echo "FAIL: final-remark validator did not detect missing barriers (status $status)"
 exit 1
fi
echo 'PASS: final-remark validator rejected missing barriers before sweeping'

fi

# Compile the real scheduler against the GC extern alone, leaving the pinned
# Haxe toolchain's other standard types intact.
mkdir -p "$work/stdlib/hl"
cp "$root/stdlib/hl/Gc.hx" "$work/stdlib/hl/Gc.hx"
"$root/.tools/haxe/haxe" -cp "$root/tests/native" -cp "$root/packages/ui/haxe" -cp "$work/stdlib" -hl "$work/frame.hl" -main FrameGcSchedulerProbe
if [[ $kernel_available == 1 ]]; then
 LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "${HL_JIT_TEST_VM:-$root/.tools/hashlink/hl}" "$work/frame.hl"
fi

"$root/.tools/haxe/haxe" -cp "$root/tests/native" -cp "$work/stdlib" -hl "$work/barrier.hl" -main GcWriteBarrierProbe
if [[ $kernel_available == 1 ]]; then
 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_THREADS=1 LD_PRELOAD="$work/mask.so" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "${HL_JIT_TEST_VM:-$root/.tools/hashlink/hl}" "$work/barrier.hl"
fi

# The test-only backend must never touch kernel tracking, even for probing/rearm.
"${CC:-cc}" -shared -fPIC "$root/tests/native/gc_no_proc_tracking.c" -ldl -o "$work/no-proc.so"
for threads in 1 4; do
 for failure in none pressure; do
  args=()
  [[ $failure == none ]] || args+=("$failure")
  HL_GC_TEST_UNSET_VALIDATION=1 HL_GC_INCREMENTAL_TEST_SOFTWARE=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_MIN_TRIGGER=65536 HL_GC_THREADS=$threads LD_PRELOAD="$work/no-proc.so" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/guards" "${args[@]}"
 done
 HL_GC_INCREMENTAL_TEST_SOFTWARE=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_THREADS=$threads LD_PRELOAD="$work/no-proc.so" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "${HL_JIT_TEST_VM:-$root/.tools/hashlink/hl}" "$work/barrier.hl"
 HL_GC_INCREMENTAL_TEST_SOFTWARE=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_THREADS=$threads LD_PRELOAD="$work/no-proc.so" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "${HL_JIT_TEST_VM:-$root/.tools/hashlink/hl}" "$work/frame.hl"
done
status=0
HL_GC_INCREMENTAL_TEST_SOFTWARE=1 HL_GC_INCREMENTAL_VALIDATE=0 LD_PRELOAD="$work/no-proc.so" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/guards" >"$work/required.log" 2>&1 || status=$?
if [[ $status != 1 ]] || ! rg -q 'Test-only software GC requires HL_GC_INCREMENTAL_VALIDATE=1' "$work/required.log"; then
 cat "$work/required.log"
 echo 'FAIL: software tracking accepted disabled validation'
 exit 1
fi
status=0
HL_GC_TEST_UNSET_VALIDATION=1 HL_GC_INCREMENTAL_TEST_SOFTWARE=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_MIN_TRIGGER=65536 HL_GC_THREADS=1 LD_PRELOAD="$work/no-proc.so:$work/drop.so" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/guards" >"$work/software-missing.log" 2>&1 || status=$?
if [[ $status != 1 ]] || ! rg -q 'GC incremental validation failed: [1-9][0-9]* reachable objects missing' "$work/software-missing.log"; then
 cat "$work/software-missing.log"
 echo 'FAIL: software tracking did not reject missing barriers'
 exit 1
fi
echo 'PASS: software-only test backend avoids proc tracking and requires validation'

# HDLL module APIs are resolved by the VM in normal use; this native probe only
# invokes runtime helpers whose dependencies are provided by libhl.
"${CC:-cc}" -D_DEFAULT_SOURCE -I"$root/vendor/hashlink/src" "$root/tests/native/gc_runtime_writes.c" -L"$library" -L"$root/out" -Wl,--allow-shlib-undefined -l:haxeon_runtime.hdll -lhl -lpthread -o "$work/runtime-writes"
for threads in 1 4; do
 HL_GC_INCREMENTAL_TEST_SOFTWARE=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_MIN_TRIGGER=65536 HL_GC_THREADS=$threads LD_PRELOAD="$work/no-proc.so" LD_LIBRARY_PATH="$library:$root/out${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/runtime-writes"
done
status=0
HL_GC_INCREMENTAL_TEST_SOFTWARE=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_MIN_TRIGGER=65536 HL_GC_THREADS=1 LD_PRELOAD="$work/no-proc.so:$work/drop.so" LD_LIBRARY_PATH="$library:$root/out${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/runtime-writes" >"$work/runtime-missing.log" 2>&1 || status=$?
if [[ $status != 1 ]] || ! rg -q 'GC incremental validation failed: [1-9][0-9]* reachable objects missing' "$work/runtime-missing.log"; then
 cat "$work/runtime-missing.log"
 echo 'FAIL: native iterator probe did not detect its missing barrier'
 exit 1
fi
echo 'PASS: native runtime mutation negative control'

"$root/.tools/haxe/haxe" -cp "$root/tests/native" -cp "$work/stdlib" -hl "$work/runtime-probe.hl" -main GcRuntimeWriteProbe
for threads in 1 4; do
 HL_GC_INCREMENTAL_TEST_SOFTWARE=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_MIN_TRIGGER=65536 HL_GC_THREADS=$threads LD_PRELOAD="$work/no-proc.so" LD_LIBRARY_PATH="$library:$root/out${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "${HL_JIT_TEST_VM:-$root/.tools/hashlink/hl}" "$work/runtime-probe.hl"
done

# Exercise FFI and module lifetimes with independently validated software tracking.
bash "$root/tests/integration/test-gc-ffi-stress.sh"

for threads in 1 4; do
 HL_GC_INCREMENTAL_TEST_SOFTWARE=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_THREADS=$threads LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/block-sizes"
 HL_GC_INCREMENTAL_TEST_SOFTWARE=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_THREADS=$threads LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/dirty-slices" software
 HL_GC_TEST_CANCEL_DIRTY=1 HL_GC_INCREMENTAL_TEST_SOFTWARE=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_THREADS=$threads LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/dirty-slices" software
done
# Pacing controls must start earlier without moving full-collection pressure limits.
"${CC:-cc}" -O2 -Wall -Wextra -Werror -I"$root/vendor/hashlink/src" "$root/tests/native/gc_pacing.c" -L"$library" -lhl -lpthread -o "$work/pacing"
for backend in 0 1; do
 [[ $backend != 0 || $kernel_available == 1 ]] || continue
 for percent in 100 50 0 NaN 99garbage 99999999999999999999; do
  expected=0; [[ $percent != 50 ]] || expected=1
  HL_GC_INCREMENTAL_START_PERCENT=$percent HL_GC_INCREMENTAL_STEP_BYTES=131072 HL_GC_INCREMENTAL_TEST_SOFTWARE=$backend HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_MIN_TRIGGER=67108864 HL_GC_INCREMENTAL=1 LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/pacing" "$expected"
 done
done
# A denied tracker must keep the ordinary full-collection start threshold.
HL_GC_TEST_DENY_PROC=1 HL_GC_INCREMENTAL_START_PERCENT=50 HL_GC_INCREMENTAL_STEP_BYTES=131072 HL_GC_INCREMENTAL_TEST_SOFTWARE=0 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_MIN_TRIGGER=67108864 HL_GC_INCREMENTAL=1 LD_PRELOAD="$work/no-proc.so" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/pacing" 0 unsupported
"${CC:-cc}" -O2 -Wall -Wextra -Werror -I"$root/vendor/hashlink/src" "$root/tests/native/gc_frame_budget.c" -L"$library" -lhl -lpthread -o "$work/frame-budget"
for backend in 0 1; do
 [[ $backend != 0 || $kernel_available == 1 ]] || continue
 for threads in 1 4; do
  HL_GC_INCREMENTAL=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_INCREMENTAL_TEST_SOFTWARE=$backend HL_GC_THREADS=$threads HL_GC_MIN_TRIGGER=67108864 LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/frame-budget"
  HL_GC_INCREMENTAL=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_INCREMENTAL_TEST_SOFTWARE=$backend HL_GC_THREADS=$threads HL_GC_MIN_TRIGGER=65536 LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/frame-budget" pressure
 done
done
HL_GC_TEST_DENY_PROC=1 HL_GC_INCREMENTAL=1 HL_GC_INCREMENTAL_TEST_SOFTWARE=0 LD_PRELOAD="$work/no-proc.so" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/frame-budget" unsupported
"${CC:-cc}" -O2 -Wall -Wextra -Werror -I"$root/vendor/hashlink/src" "$root/tests/native/gc_reclaim.c" -L"$library" -lhl -lpthread -o "$work/reclaim"
for backend in 0 1; do
 [[ $backend != 0 || $kernel_available == 1 ]] || continue
 for threads in 1 4; do
  for fast in 0 1; do
   for mode in finish cancel pressure; do
    reclaim_trigger=67108864; [[ $mode != pressure ]] || reclaim_trigger=65536
    HL_GC_ALLOC_FAST=$fast HL_GC_KEEP_EMPTY=0 HL_GC_MIN_TRIGGER=$reclaim_trigger HL_GC_INCREMENTAL=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_INCREMENTAL_TEST_SOFTWARE=$backend HL_GC_THREADS=$threads LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/reclaim" "$mode"
   done
  done
 done
done
