#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
output=${1:-$root/out/bench/gc-scans}
export HL_GC_SCAN_PROFILE=1
export GC_BOUNDARY_REPEATS=${GC_BOUNDARY_REPEATS:-1}
bash "$root/tests/bench/incremental-gc/run-large-object.sh" "$output"
python3 "$root/tests/bench/incremental-gc/summarize-scans.py" "$output" | tee "$output/scan-summary.txt"
