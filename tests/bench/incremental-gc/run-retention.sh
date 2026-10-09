#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
output=${1:-$root/out/bench/gc-retention}
mkdir -p "$output"; output=$(cd "$output" && pwd)
library=${HL_GC_TEST_LIBRARY_DIR:-$root/.tools/hashlink}
for fixture in gc_retention; do
 "${CC:-cc}" -O2 -Wall -Wextra -Werror -I"$root/vendor/hashlink/src" "$root/tests/native/$fixture.c" -L"$library" -lhl -lpthread -o "$output/$fixture"
done
export HL_GC_RETENTION_PROFILE=1 HL_GC_SCAN_PROFILE=1 HL_GC_INCREMENTAL_VALIDATE=1 HL_GC_INCREMENTAL=1 HL_GC_THREADS=1 HL_GC_MIN_TRIGGER=67108864
export LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
for backend in 0 1; do
 HL_GC_INCREMENTAL_TEST_SOFTWARE=$backend "$output/gc_retention" > "$output/fixture-$backend.log" 2>&1
 python3 - "$output/fixture-$backend.log" <<'PY'
import sys
rows=[dict(x.split('=',1) for x in line.strip().split(',')[1:]) for line in open(sys.argv[1]) if line.startswith('GC-RETENTION,')]
assert sum(int(r['bytes']) for r in rows if r['black']=='1' and r['reachable']=='0')==32, rows
assert sum(int(r['bytes']) for r in rows if r['black']=='1' and r['reachable']=='1')==1048576, rows
assert any(r['black']=='1' and r['reachable']=='0' and r['age_bucket']=='1' and r['bytes']=='32' for r in rows), rows
PY
done
export HL_GC_INCREMENTAL_TEST_SOFTWARE=0
"${CC:-cc}" -O2 -Wall -Wextra -Werror -D_DEFAULT_SOURCE -I"$root/vendor/hashlink/src" "$root/tests/bench/incremental-gc/convergence.c" -L"$library" -lhl -lpthread -o "$output/boundary"
sha256sum "$library/libhl.so" "$root/vendor/hashlink/src/gc_incremental.c" > "$output/environment.txt"
for kind in refs zeros bytes; do
 "$output/boundary" "boundary-$kind" "${GC_RETENTION_FRAMES:-600}" "${GC_RETENTION_NODES:-100000}" 1 1000 0 1048576 4194304 > "$output/$kind.csv" 2> "$output/$kind.log"
done
python3 "$root/tests/bench/incremental-gc/summarize-retention.py" "$output"
