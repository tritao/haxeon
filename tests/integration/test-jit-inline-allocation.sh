#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
source "$root/scripts/lib/env.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-jit-alloc.XXXXXX")
trap 'rm -rf "$work"' EXIT
library=${HL_GC_TEST_LIBRARY_DIR:-$("$root/scripts/hashlink-path.sh")}
hooks=$(dirname "$(haxeon_native_test jitalloc.hdll)")
"$root/.tools/haxe/haxe" -cp "$root/tests/native" -hl "$work/probe.hl" -main JitAllocationProbe
for mode in 0 1; do
 HL_JIT_ALLOC_CENSUS="$work/census-$mode.json" HL_JIT_ALLOC_INLINE=$mode HL_GC_MIN_TRIGGER=65536 PATH="$hooks:$library:$PATH" LD_LIBRARY_PATH="$hooks:$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" DYLD_LIBRARY_PATH="$hooks:$library${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "${HL_JIT_TEST_VM:-$("$root/scripts/hashlink-path.sh")/hl}" "$work/probe.hl"
 python3 - "$work/census-$mode.json" <<'PYCODE'
import json,sys
rows=json.load(open(sys.argv[1]))['types']
assert sum(row['count'] for row in rows if row['type']=='Node24')==1000,rows
PYCODE
done
