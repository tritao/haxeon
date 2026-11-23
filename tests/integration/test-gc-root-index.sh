#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-gc-roots.XXXXXX")
trap 'rm -rf "$work"' EXIT
library=$("$root/scripts/hashlink-path.sh" --lib-dir)
"${CC:-cc}" -I"$root/vendor/hashlink/src" "$root/tests/native/gc_root_index.c" -L"$library" -lhl -lm -ldl -o "$work/roots"
for mode in 0 1; do
    HL_GC_ALLOC_FAST=$mode LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        DYLD_LIBRARY_PATH="$library${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$work/roots"
done
