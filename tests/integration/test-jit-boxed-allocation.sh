#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-jit-box.XXXXXX")
trap 'rm -rf "$work"' EXIT
library=${HL_GC_TEST_LIBRARY_DIR:-$("$root/scripts/hashlink-path.sh")}
# Windows looks for DLLs and HashLink libraries on PATH.
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) export PATH="$work:$library:$PATH" ;; esac
"${CC:-cc}" -shared -fPIC -I"$root/vendor/hashlink/src" "$root/tests/native/jit_box_hooks.c" -L"$library" -lhl -o "$work/jitbox.hdll"
"$root/.tools/haxe/haxe" -cp "$root/tests/native" -hl "$work/probe.hl" -main BoxAllocationProbe
for mode in 0 1; do
 status=0
 HL_JIT_BOX_CENSUS="$work/census-$mode.json" HL_JIT_ALLOC_INLINE=1 HL_JIT_ALLOC_BOX=$mode HL_GC_MIN_TRIGGER=65536 LD_LIBRARY_PATH="$work:$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" DYLD_LIBRARY_PATH="$work:$library${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "${HL_JIT_TEST_VM:-$("$root/scripts/hashlink-path.sh")/hl}" "$work/probe.hl" || status=$?
 # The VM reports whether compiled code allocates inline on this target (hl_jit_alloc_supported).
 if [[ $status == 77 ]]; then
  echo 'SKIP: this target has no inline JIT allocation'
  exit 0
 fi
 [[ $status == 0 ]] || exit "$status"
 python3 - "$work/census-$mode.json" <<'PYCODE'
import json,sys
rows=json.load(open(sys.argv[1]))['types']
assert sum(row['count'] for row in rows if row['type']=='i32')==1000,rows
PYCODE
done
