#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
source "$root/scripts/lib/env.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-gc-empty.XXXXXX")
trap 'rm -rf "$work"' EXIT
library=$("$root/scripts/hashlink-path.sh" --lib-dir)
guards=$(haxeon_native_test gc_empty_pages)
for mode in 0 1; do
 HL_GC_KEEP_EMPTY=$mode HL_GC_EMPTY_BUDGET=4194304 PATH="$library:$PATH" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$guards" "$mode"
done
HL_GC_KEEP_EMPTY=1 HL_GC_EMPTY_BUDGET=0 PATH="$library:$PATH" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$guards" 0
