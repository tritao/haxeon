#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
formatter="$root_dir/.tools/formatter/run.js"

if [[ ! -f "$formatter" ]]; then
    echo "missing local formatter; run ./scripts/bootstrap-tools.sh first" >&2
    exit 1
fi

arguments=(-s "$root_dir/src" -s "$root_dir/tests" -s "$root_dir/benchmarks")
if [[ ${1:-} == "--check" ]]; then
    arguments+=(--check)
elif [[ $# -ne 0 ]]; then
    echo "usage: $0 [--check]" >&2
    exit 2
fi

if [[ ${1:-} == "--check" ]]; then
    node "$formatter" "${arguments[@]}"
    exit
fi

for _ in 1 2 3; do
    node "$formatter" "${arguments[@]}"
    if node "$formatter" "${arguments[@]}" --check >/dev/null; then
        exit
    fi
done

echo "formatter did not reach a stable result after three passes" >&2
exit 1
