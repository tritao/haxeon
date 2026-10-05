#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-gc-empty.XXXXXX")
trap 'rm -rf "$work"' EXIT
library=${HL_GC_TEST_LIBRARY_DIR:-$root/.tools/hashlink}
"${CC:-cc}" -I"$root/vendor/hashlink/src" "$root/tests/native/gc_empty_pages.c" -L"$library" -lhl -lpthread -o "$work/guards"
for mode in 0 1; do
 HL_GC_KEEP_EMPTY=$mode HL_GC_EMPTY_BUDGET=4194304 LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/guards" "$mode"
done
HL_GC_KEEP_EMPTY=1 HL_GC_EMPTY_BUDGET=0 LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/guards" 0
