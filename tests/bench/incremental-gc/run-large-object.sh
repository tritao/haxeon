#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
output=${1:-$root/out/bench/gc-large-object}
mkdir -p "$output"
output=$(cd "$output" && pwd)
library=${HL_GC_TEST_LIBRARY_DIR:-$root/.tools/hashlink}
"${CC:-cc}" -O2 -Wall -Wextra -Werror -D_DEFAULT_SOURCE -I"$root/vendor/hashlink/src" "$root/tests/bench/incremental-gc/convergence.c" -L"$library" -lhl -lpthread -o "$output/boundary"
runtime_hash=$(sha256sum "$library/libhl.so")
frames=${GC_BOUNDARY_FRAMES:-600}
nodes=${GC_BOUNDARY_NODES:-500000}
repeats=${GC_BOUNDARY_REPEATS:-2}
budget=${GC_BOUNDARY_BUDGET_US:-1000}
volume=${GC_BOUNDARY_BYTES_PER_FRAME:-4194304}
export HL_GC_INCREMENTAL_VALIDATE=${GC_BOUNDARY_VALIDATE:-0}
export HL_GC_INCREMENTAL_TEST_SOFTWARE=${GC_BOUNDARY_SOFTWARE:-0}
export HL_GC_MIN_TRIGGER=67108864 HL_GC_INCREMENTAL=1 HL_GC_LATENCY_TRACE=0
export LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
{
 uname -a
 printf 'scan_profile=%s\n' "${HL_GC_SCAN_PROFILE:-0}"
 printf 'frames=%s nodes=%s repeats=%s budget_us=%s volume=%s validate=%s software=%s auto=0\n' "$frames" "$nodes" "$repeats" "$budget" "$volume" "$HL_GC_INCREMENTAL_VALIDATE" "$HL_GC_INCREMENTAL_TEST_SOFTWARE"
 "${CC:-cc}" --version | head -1
 sha256sum "$root/tests/bench/incremental-gc/convergence.c" "$root/vendor/hashlink/src/allocator.c" "$root/vendor/hashlink/src/gc_incremental.c" "$root/vendor/hashlink/src/gc_write_tracking.c" "$root/vendor/hashlink/src/gc.c" "$library/libhl.so"
} > "$output/environment.txt"
for threads in 1 4; do
 for ((repeat=1;repeat<=repeats;repeat++)); do
  # Reverse order on alternate repeats to reduce fixed-order bias.
  kinds=(bytes refs zeros); sizes=(1048568 1048576 1048584)
  if ((repeat%2==0)); then kinds=(zeros refs bytes); sizes=(1048584 1048576 1048568); fi
  for kind in "${kinds[@]}"; do
   for size in "${sizes[@]}"; do
    file="$output/$kind-s$size-t$threads-r$repeat"
    HL_GC_THREADS=$threads "$output/boundary" "boundary-$kind" "$frames" "$nodes" 1 "$budget" 0 "$size" "$volume" > "$file.csv" 2> "$file.log"
   done
  done
 done
done
if [[ $(sha256sum "$library/libhl.so") != "$runtime_hash" ]]; then
 echo "FAIL: runtime changed during boundary experiment"
 exit 1
fi
python3 "$root/tests/bench/incremental-gc/summarize-large-object.py" "$output" | tee "$output/summary.txt"
echo "Raw large-object samples: $output"
