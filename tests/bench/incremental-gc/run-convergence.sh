#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
output=${1:-$root/out/bench/gc-convergence}
mkdir -p "$output"
output=$(cd "$output" && pwd)
library=${HL_GC_TEST_LIBRARY_DIR:-$root/.tools/hashlink}
"${CC:-cc}" -O2 -D_DEFAULT_SOURCE -I"$root/vendor/hashlink/src" "$root/tests/bench/incremental-gc/convergence.c" -L"$library" -lhl -lpthread -o "$output/convergence"
frames=${GC_STRESS_FRAMES:-600}
nodes=${GC_STRESS_NODES:-500000}
scale=${GC_STRESS_SCALE:-1}
budget=${GC_STRESS_BUDGET_US:-1000}
automatic=${GC_STRESS_AUTO:-0}
repeats=${GC_STRESS_REPEATS:-2}
export HL_GC_INCREMENTAL_VALIDATE=${GC_STRESS_VALIDATE:-0}
export HL_GC_INCREMENTAL_TEST_SOFTWARE=${GC_STRESS_SOFTWARE:-0}
export HL_GC_MIN_TRIGGER=${GC_STRESS_MIN_TRIGGER:-67108864}
export HL_GC_INCREMENTAL=1 HL_GC_LATENCY_TRACE=0
export LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
{
 uname -a
 printf 'scan_profile=%s\n' "${HL_GC_SCAN_PROFILE:-0}"
 printf 'frames=%s nodes=%s scale=%s budget_us=%s auto=%s repeats=%s validate=%s software=%s min_trigger=%s\n' "$frames" "$nodes" "$scale" "$budget" "$automatic" "$repeats" "$HL_GC_INCREMENTAL_VALIDATE" "$HL_GC_INCREMENTAL_TEST_SOFTWARE" "$HL_GC_MIN_TRIGGER"
 "${CC:-cc}" --version | head -1
 sha256sum "$root/vendor/hashlink/src/gc_incremental.c" "$root/vendor/hashlink/src/gc_write_tracking.c" "$root/vendor/hashlink/src/gc.c" "$root/tests/bench/incremental-gc/convergence.c" "$library/libhl.so"
 git -C "$root/vendor/hashlink" rev-parse HEAD
} > "$output/environment.txt"
for threads in 1 4; do
 for workload in rewrite arrays graphs overload; do
  for ((repeat=1;repeat<=repeats;repeat++)); do
   file="$output/$workload-t$threads-r$repeat"
   HL_GC_THREADS=$threads "$output/convergence" "$workload" "$frames" "$nodes" "$scale" "$budget" "$automatic" > "$file.csv" 2> "$file.log"
  done
 done
done
python3 "$root/tests/bench/incremental-gc/summarize-convergence.py" "$output" | tee "$output/summary.txt"
echo "Raw convergence samples: $output"
