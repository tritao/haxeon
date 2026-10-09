#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
before=$(cd "${1:?usage: run-boundary-paired.sh BEFORE_LIBRARY OUTPUT}" && pwd)
output=${2:-$root/out/bench/gc-boundary-paired}
mkdir -p "$output"; output=$(cd "$output" && pwd)
after=${HL_GC_TEST_LIBRARY_DIR:-$root/.tools/hashlink}
"${CC:-cc}" -O2 -Wall -Wextra -Werror -D_DEFAULT_SOURCE -I"$root/vendor/hashlink/src" "$root/tests/bench/incremental-gc/convergence.c" -L"$after" -lhl -lpthread -o "$output/boundary"
export HL_GC_THREADS=1 HL_GC_SCAN_PROFILE=0 HL_GC_LATENCY_TRACE=0 HL_GC_INCREMENTAL_TEST_SOFTWARE=0 HL_GC_INCREMENTAL_VALIDATE=0 HL_GC_MIN_TRIGGER=67108864 HL_GC_INCREMENTAL=1
frames=${GC_BOUNDARY_FRAMES:-600}; nodes=${GC_BOUNDARY_NODES:-500000}; repeats=${GC_BOUNDARY_REPEATS:-2}
read -ra sizes <<< "${GC_BOUNDARY_SIZES:-1048568 1048576 1048584}"
launcher=(); if [[ -n ${GC_BOUNDARY_CPU:-} ]]; then launcher=(taskset -c "$GC_BOUNDARY_CPU"); fi
before_hash=$(sha256sum "$before/libhl.so"); after_hash=$(sha256sum "$after/libhl.so")
{
 uname -a
 printf 'frames=%s nodes=%s repeats=%s cpu=%s sizes=%s\n' "$frames" "$nodes" "$repeats" "${GC_BOUNDARY_CPU:-unrestricted}" "${sizes[*]}"
 printf '%s\n%s\n' "$before_hash" "$after_hash"
 sha256sum "$root/tests/bench/incremental-gc/convergence.c" "$root/vendor/hashlink/src/allocator.c" "$root/vendor/hashlink/src/gc_incremental.c"
} > "$output/environment.txt"
for ((repeat=1;repeat<=repeats;repeat++)); do
 for kind in refs zeros bytes; do
  for size in "${sizes[@]}"; do
   versions=(before after); if ((repeat%2==0)); then versions=(after before); fi
   for version in "${versions[@]}"; do
    library=$before; [[ $version == before ]] || library=$after
    file="$output/$kind-s$size-$version-r$repeat"
    LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "${launcher[@]}" "$output/boundary" "boundary-$kind" "$frames" "$nodes" 1 1000 0 "$size" 4194304 > "$file.csv" 2> "$file.log"
   done
  done
 done
done
[[ $(sha256sum "$before/libhl.so") == "$before_hash" && $(sha256sum "$after/libhl.so") == "$after_hash" ]] || { echo 'FAIL: runtime changed'; exit 1; }
python3 - "$output" "$repeats" "$frames" "${sizes[@]}" <<'PY'
import csv, pathlib, sys
root=pathlib.Path(sys.argv[1]); repeats=int(sys.argv[2]); frames=int(sys.argv[3]); results=[]
for kind in ('refs','zeros','bytes'):
 for size in sys.argv[4:]:
  for version in ('before','after'):
   for repeat in range(1,repeats+1):
    stem=root/f'{kind}-s{size}-{version}-r{repeat}'
    rows=list(csv.DictReader(stem.with_suffix('.csv').open()))
    ends=[s for s in stem.with_suffix('.log').read_text().splitlines() if s.startswith('STRESS-END,')]
    if len(rows)!=frames or len(ends)!=1: raise SystemExit('FAIL: incomplete paired run')
    end=dict(x.split('=',1) for x in ends[0].split(',')[1:])
    if int(end['frame_allocated'])!=4194304 or int(end['primary_requested'])!=int(size): raise SystemExit('FAIL: wrong allocation volume')
    if any(int(b['allocated_bytes'])-int(a['allocated_bytes'])!=4194304 for a,b in zip(rows,rows[1:])): raise SystemExit('FAIL: allocation rate')
    last=rows[-1]
    if int(last['tracking_fallbacks']) or last['full_collections']!=last['pressure_fallbacks']: raise SystemExit('FAIL: unexplained major')
    work=sorted(float(r['frame_ms']) for r in rows)
    result=dict(kind=kind,size=int(size),version=version,repeat=repeat,cycles=int(last['cycles_completed']),pressure=int(last['pressure_fallbacks']),heap_mib=max(int(r['heap_bytes']) for r in rows)/2**20,p99_ms=work[(len(work)-1)*99//100],max_ms=work[-1])
    results.append(result); print(result)
with (root/'summary.csv').open('w') as f:
 writer=csv.DictWriter(f,fieldnames=results[0]); writer.writeheader(); writer.writerows(results)
PY
