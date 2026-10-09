#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
output=${1:-$root/out/bench/gc-latency}
mkdir -p "$output"
output=$(cd "$output" && pwd)
library=${HL_GC_TEST_LIBRARY_DIR:-$root/.tools/hashlink}
"${CC:-cc}" -O2 -D_DEFAULT_SOURCE -I"$root/vendor/hashlink/src" "$root/tests/bench/incremental-gc/latency.c" -L"$library" -lhl -lpthread -o "$output/latency"
# Timed runs exclude validation and phase logging. Run correctness guards first.
export HL_GC_INCREMENTAL_VALIDATE=0 HL_GC_INCREMENTAL_TEST_SOFTWARE=0 HL_GC_LATENCY_TRACE=0 HL_GC_INCREMENTAL=0 HL_GC_SCAN_PROFILE=0
export LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
frames=${GC_BENCH_FRAMES:-1200}
nodes=${GC_BENCH_NODES:-500000}
{
 uname -a
 "${CC:-cc}" --version | head -1
 printf 'frames=%s nodes=%s budget_us=1000 churn_bytes_per_frame=34816\n' "$frames" "$nodes"
 sha256sum "$root/vendor/hashlink/src/gc_incremental.c" "$root/vendor/hashlink/src/gc_write_tracking.c" "$library/libhl.so"
 git -C "$root/vendor/hashlink" rev-parse HEAD
} > "$output/environment.txt"
for threads in 1 4; do
 run=0
 for mode in 0 1 1 0; do
  run=$((run+1))
  HL_GC_THREADS=$threads "$output/latency" "$mode" "$frames" "$nodes" > "$output/t$threads-m$mode-r$run.csv"
 done
 # Separate diagnostic run: logging overhead makes its frame timings unsuitable
 # for comparisons. Phase times exclude logging and include validation only if enabled.
 HL_GC_THREADS=$threads HL_GC_LATENCY_TRACE=1 "$output/latency" 1 "$frames" "$nodes" > "$output/trace-t$threads.csv" 2> "$output/phases-t$threads.log"
done
python3 "$root/tests/bench/incremental-gc/summarize.py" "$output" | tee "$output/summary.txt"
echo "Raw samples and phase logs: $output"
