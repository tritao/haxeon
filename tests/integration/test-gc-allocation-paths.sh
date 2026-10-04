#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-gc-allocation.XXXXXX")
trap 'rm -rf "$work"' EXIT
library=${HL_GC_TEST_LIBRARY_DIR:-$root/.tools/hashlink}
"${CC:-cc}" -I"$root/vendor/hashlink/src" "$root/tests/native/gc_allocation_paths.c" -L"$library" -lhl -o "$work/guards"
for mode in 0 1; do
	HL_GC_ALLOC_FAST=$mode LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" DYLD_LIBRARY_PATH="$library${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
		"$work/guards" "$work/census-$mode.json"
	python3 - "$work/census-$mode.json" <<'PY'
import json,sys
with open(sys.argv[1]) as file:
    data=json.load(file)
assert data['allocations']==128, data
PY
done
printf '%s\n' 'PASS: allocation guards and census count with the fast entry disabled and enabled'
