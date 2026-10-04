#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-jit-box.XXXXXX")
trap 'rm -rf "$work"' EXIT
library=${HL_GC_TEST_LIBRARY_DIR:-$root/.tools/hashlink}
"${CC:-cc}" -shared -fPIC -I"$root/vendor/hashlink/src" "$root/tests/native/jit_box_hooks.c" -L"$library" -lhl -o "$work/jitbox.hdll"
"$root/.tools/haxe/haxe" -cp "$root/tests/native" -hl "$work/probe.hl" -main BoxAllocationProbe
for mode in 0 1; do
 HL_JIT_BOX_CENSUS="$work/census-$mode.json" HL_JIT_ALLOC_INLINE=1 HL_JIT_ALLOC_BOX=$mode HL_GC_MIN_TRIGGER=65536 LD_LIBRARY_PATH="$work:$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "${HL_JIT_TEST_VM:-$root/.tools/hashlink/hl}" "$work/probe.hl"
 python3 - "$work/census-$mode.json" <<'PYCODE'
import json,sys
rows=json.load(open(sys.argv[1]))['types']
assert sum(row['count'] for row in rows if row['type']=='i32')==1000,rows
PYCODE
done
