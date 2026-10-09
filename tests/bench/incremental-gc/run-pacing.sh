#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
output=${1:-$root/out/bench/gc-pacing}
mkdir -p "$output"; output=$(cd "$output" && pwd)
library=${HL_GC_TEST_LIBRARY_DIR:-$root/.tools/hashlink}
"${CC:-cc}" -O2 -Wall -Wextra -Werror -D_DEFAULT_SOURCE -I"$root/vendor/hashlink/src" "$root/tests/bench/incremental-gc/convergence.c" -L"$library" -lhl -lpthread -o "$output/convergence"
export LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export HL_GC_INCREMENTAL=1 HL_GC_THREADS=1 HL_GC_MIN_TRIGGER=67108864 HL_GC_LATENCY_TRACE=0
export HL_GC_INCREMENTAL_VALIDATE=${GC_PACING_VALIDATE:-0} HL_GC_INCREMENTAL_TEST_SOFTWARE=${GC_PACING_SOFTWARE:-0}
export HL_GC_RETENTION_PROFILE=${GC_PACING_RETENTION:-0} HL_GC_SCAN_PROFILE=0
frames=${GC_PACING_FRAMES:-600}; nodes=${GC_PACING_NODES:-100000}; repeats=${GC_PACING_REPEATS:-3}
launcher=(); if [[ -n ${GC_PACING_CPU:-} ]]; then launcher=(taskset -c "$GC_PACING_CPU"); fi
hash=$(sha256sum "$library/libhl.so")
{
 uname -a
 printf 'frames=%s nodes=%s repeats=%s cpu=%s validate=%s retention=%s software=%s auto=2\n' "$frames" "$nodes" "$repeats" "${GC_PACING_CPU:-unrestricted}" "$HL_GC_INCREMENTAL_VALIDATE" "$HL_GC_RETENTION_PROFILE" "$HL_GC_INCREMENTAL_TEST_SOFTWARE"
 printf '%s\n' "$hash"
 sha256sum "$root/vendor/hashlink/src/gc.c" "$root/tests/bench/incremental-gc/convergence.c"
} > "$output/environment.txt"
for ((repeat=1;repeat<=repeats;repeat++)); do
 policies=(baseline early dense early-dense)
 if ((repeat%2==0)); then policies=(early-dense dense early baseline); fi
 for kind in refs zeros bytes; do
  for policy in "${policies[@]}"; do
   percent=100; step=262144
   [[ $policy != early && $policy != early-dense ]] || percent=50
   [[ $policy != dense && $policy != early-dense ]] || step=131072
   file="$output/$kind-$policy-r$repeat"
   HL_GC_INCREMENTAL_START_PERCENT=$percent HL_GC_INCREMENTAL_STEP_BYTES=$step "${launcher[@]}" "$output/convergence" "boundary-$kind" "$frames" "$nodes" 1 1000 2 1048576 4194304 > "$file.csv" 2> "$file.log"
  done
 done
done
[[ $(sha256sum "$library/libhl.so") == "$hash" ]] || { echo 'FAIL: runtime changed'; exit 1; }
python3 - "$output" "$frames" "$repeats" <<'PY'
import csv, pathlib, sys
root=pathlib.Path(sys.argv[1]); frames=int(sys.argv[2]); repeats=int(sys.argv[3]); results=[]
for kind in ('refs','zeros','bytes'):
 for policy in ('baseline','early','dense','early-dense'):
  for repeat in range(1,repeats+1):
   stem=root/f'{kind}-{policy}-r{repeat}'
   rows=list(csv.DictReader(stem.with_suffix('.csv').open()))
   assert len(rows)==frames
   assert all(int(b['allocated_bytes'])-int(a['allocated_bytes'])==4194304 for a,b in zip(rows,rows[1:]))
   last=rows[-1]
   assert int(last['tracking_fallbacks'])==0
   assert last['full_collections']==last['pressure_fallbacks']
   logs=stem.with_suffix('.log').read_text().splitlines()
   assert len([s for s in logs if s.startswith('STRESS-END,')])==1
   times=sorted(float(r['frame_ms']) for r in rows)
   dead=[]; draining=False; per_cycle={}
   for line in logs:
    if line=='GC-SCAN-DRAIN': draining=True
    if not draining and line.startswith('GC-RETENTION,'):
     r=dict(x.split('=',1) for x in line.split(',')[1:])
     if r['black']=='1' and r['reachable']=='0': per_cycle[r['cycle']]=per_cycle.get(r['cycle'],0)+int(r['bytes'])
   import statistics
   dead=list(per_cycle.values())
   result=dict(kind=kind,policy=policy,repeat=repeat,cycles=int(last['cycles_completed']),pressure=int(last['pressure_fallbacks']),heap_mib=max(int(r['heap_bytes']) for r in rows)/2**20,median_ms=statistics.median(times),p99_ms=times[(len(times)-1)*99//100],max_ms=times[-1],total_frame_ms=sum(times),black_dead_median_mib=statistics.median(dead)/2**20 if dead else '')
   results.append(result); print(result)
with (root/'summary.csv').open('w') as f:
 writer=csv.DictWriter(f,fieldnames=results[0]); writer.writeheader(); writer.writerows(results)
PY
