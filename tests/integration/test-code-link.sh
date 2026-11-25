#!/usr/bin/env bash
# HLB 9: per-module sections link at load into the tables a dense file of the same program reads into, the linked program
# runs, and every load error names its section and key (tests/native/code_link.c). hldump reads a sectioned file too.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
source "$root/scripts/lib/env.sh"
test=$(haxeon_native_test code_link)
"$test"
hldump=${HLDUMP:-$("$root/scripts/hashlink-path.sh" --build-dir)/hashlink/bin/hldump}
image=$haxeon_suite_out/code-link.hl
"$test" --write "$image"
dump=$("$hldump" "$image")
grep -q '^hlb version=9 debug=1 entry=Main.main' <<<"$dump" || { echo "FAIL: hldump does not read the HLB 9 file:"; head -5 <<<"$dump"; exit 1; }
echo "PASS: hldump reads an HLB 9 file"
