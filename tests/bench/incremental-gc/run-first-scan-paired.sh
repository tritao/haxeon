#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
before=$(cd "${1:?usage: run-first-scan-paired.sh BEFORE_LIBRARY OUTPUT}" && pwd)
output=${2:-$root/out/bench/gc-first-scan-paired}
mkdir -p "$output"
output=$(cd "$output" && pwd)
after=${HL_GC_TEST_LIBRARY_DIR:-$root/.tools/hashlink}
"${CC:-cc}" -O2 -Wall -Wextra -Werror -D_DEFAULT_SOURCE -I"$root/vendor/hashlink/src" "$root/tests/bench/incremental-gc/first-scan.c" -L"$after" -lhl -lpthread -o "$output/first-scan"
export HL_GC_THREADS=1 HL_GC_SCAN_PROFILE=0 HL_GC_LATENCY_TRACE=0 HL_GC_INCREMENTAL_TEST_SOFTWARE=0 HL_GC_INCREMENTAL_VALIDATE=0
mib=${GC_FIRST_SCAN_MIB:-64}; cycles=${GC_FIRST_SCAN_CYCLES:-16}; repeats=${GC_FIRST_SCAN_REPEATS:-3}
launcher=()
if [[ -n ${GC_FIRST_SCAN_CPU:-} ]]; then launcher=(taskset -c "$GC_FIRST_SCAN_CPU"); fi
before_hash=$(sha256sum "$before/libhl.so"); after_hash=$(sha256sum "$after/libhl.so")
{
 uname -a
 printf 'mib=%s cycles=%s repeats=%s cpu=%s perf=%s\n' "$mib" "$cycles" "$repeats" "${GC_FIRST_SCAN_CPU:-unrestricted}" "${GC_FIRST_SCAN_PERF:-0}"
 printf '%s\n%s\n' "$before_hash" "$after_hash"
 sha256sum "$root/tests/bench/incremental-gc/first-scan.c" "$root/vendor/hashlink/src/allocator.c" "$root/vendor/hashlink/src/gc_incremental.c"
} > "$output/environment.txt"
for ((repeat=1;repeat<=repeats;repeat++)); do
 for mode in local scattered interior invalid null; do
  versions=(before after)
  if ((repeat%2==0)); then versions=(after before); fi
  for version in "${versions[@]}"; do
   library=$before; [[ $version == before ]] || library=$after
   file="$output/$mode-$version-r$repeat"
   profile=()
   if [[ ${GC_FIRST_SCAN_PERF:-0} == 1 ]]; then
    profile=(perf stat -x, -e instructions:u,cycles:u,task-clock -o "$file.perf")
   fi
   LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "${profile[@]}" "${launcher[@]}" "$output/first-scan" "$mode" "$mib" "$cycles" > "$file.csv" 2> "$file.log"
  done
 done
done
[[ $(sha256sum "$before/libhl.so") == "$before_hash" && $(sha256sum "$after/libhl.so") == "$after_hash" ]] || { echo 'FAIL: runtime changed'; exit 1; }
python3 - "$output" "$repeats" "$cycles" <<'PY'
import csv, pathlib, statistics, sys
root=pathlib.Path(sys.argv[1]); repeats=int(sys.argv[2]); cycles=int(sys.argv[3]); results=[]
for mode in ('local','scattered','interior','invalid','null'):
 rates={}
 for version in ('before','after'):
  rates[version]=[]
  for repeat in range(1,repeats+1):
   stem=root/f'{mode}-{version}-r{repeat}'
   rows=list(csv.DictReader(stem.with_suffix('.csv').open()))
   if len(rows)!=cycles: raise SystemExit('FAIL: incomplete paired run')
   volume=sum(int(r['bytes']) for r in rows)/2**20
   cpu=sum(float(r['cpu_ms']) for r in rows)/1000
   wall=sum(float(r['elapsed_ms']) for r in rows)/1000
   rate=volume/cpu; rates[version].append(rate)
   instructions=0
   if stem.with_suffix('.perf').exists():
    for line in stem.with_suffix('.perf').read_text().splitlines():
     cols=line.split(',')
     if len(cols)>2 and 'instructions' in cols[2] and cols[0].strip().isdigit(): instructions+=int(cols[0])
   results.append(dict(mode=mode,version=version,repeat=repeat,cpu_mib_per_second=rate,wall_mib_per_second=volume/wall,instructions=instructions))
 b=statistics.median(rates['before']); a=statistics.median(rates['after'])
 print(f'{mode}: median CPU throughput {b:.1f} -> {a:.1f} MiB/s ({a/b:.2f}x)')
with (root/'summary.csv').open('w') as f:
 writer=csv.DictWriter(f,fieldnames=results[0]); writer.writeheader(); writer.writerows(results)
PY
