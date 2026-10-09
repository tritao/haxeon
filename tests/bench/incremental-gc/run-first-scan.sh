#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
output=${1:-$root/out/bench/gc-first-scan}
mkdir -p "$output"
output=$(cd "$output" && pwd)
library=${HL_GC_TEST_LIBRARY_DIR:-$root/.tools/hashlink}
"${CC:-cc}" -O2 -Wall -Wextra -Werror -D_DEFAULT_SOURCE -I"$root/vendor/hashlink/src" "$root/tests/bench/incremental-gc/first-scan.c" -L"$library" -lhl -lpthread -o "$output/first-scan"
export LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export HL_GC_THREADS=1 HL_GC_SCAN_PROFILE=0 HL_GC_LATENCY_TRACE=0 HL_GC_INCREMENTAL_TEST_SOFTWARE=0 HL_GC_INCREMENTAL_VALIDATE=0
mib=${GC_FIRST_SCAN_MIB:-64}
cycles=${GC_FIRST_SCAN_CYCLES:-16}
repeats=${GC_FIRST_SCAN_REPEATS:-3}
runtime_hash=$(sha256sum "$library/libhl.so")
{
 uname -a
 printf 'mib=%s cycles=%s repeats=%s budget_us=1000\n' "$mib" "$cycles" "$repeats"
 sha256sum "$library/libhl.so" "$root/vendor/hashlink/src/allocator.c" "$root/vendor/hashlink/src/gc_incremental.c" "$root/tests/bench/incremental-gc/first-scan.c"
} > "$output/environment.txt"
for ((repeat=1;repeat<=repeats;repeat++)); do
 modes=(local scattered interior invalid null)
 if ((repeat%2==0)); then modes=(null invalid interior scattered local); fi
 for mode in "${modes[@]}"; do
  "$output/first-scan" "$mode" "$mib" "$cycles" > "$output/$mode-r$repeat.csv" 2> "$output/$mode-r$repeat.log"
 done
done
[[ $(sha256sum "$library/libhl.so") == "$runtime_hash" ]] || { echo 'FAIL: runtime changed'; exit 1; }
python3 - "$output" "$repeats" "$cycles" <<'PY'
import csv, pathlib, sys
root=pathlib.Path(sys.argv[1]); repeats=int(sys.argv[2]); cycles=int(sys.argv[3])
with (root/'summary.csv').open('w') as output:
 writer=csv.writer(output); writer.writerow(('mode','repeat','mib_per_second','cpu_mib_per_second','mean_cycle_ms'))
 for mode in ('local','scattered','interior','invalid','null'):
  for repeat in range(1,repeats+1):
   rows=list(csv.DictReader((root/f'{mode}-r{repeat}.csv').open()))
   if len(rows)!=cycles: raise SystemExit('FAIL: incomplete scan run')
   seconds=sum(float(r['elapsed_ms']) for r in rows)/1000
   rate=sum(int(r['bytes']) for r in rows)/2**20/seconds
   cpu_seconds=sum(float(r['cpu_ms']) for r in rows)/1000
   cpu_rate=sum(int(r['bytes']) for r in rows)/2**20/cpu_seconds
   writer.writerow((mode,repeat,rate,cpu_rate,seconds*1000/cycles))
   print(f'{mode} repeat={repeat}: {rate:.1f} MiB/s wall; {cpu_rate:.1f} MiB/s CPU; mean_cycle_ms={seconds*1000/cycles:.3f}')
PY
