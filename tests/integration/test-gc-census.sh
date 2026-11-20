#!/usr/bin/env bash
# The heap census (vendor/hashlink/src/gc_census.c) reports a known allocation, from hl_gc_census and from a collection
# (HL_GC_CENSUS_AT), counts pages without collecting (HL_GC_CENSUS_NOGC), and prints nothing when it is not asked for.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
library=${HL_GC_TEST_LIBRARY_DIR:-$("$root/scripts/hashlink-path.sh")}
source "$root/scripts/lib/env.sh"
census=$(haxeon_native_test gc_census)
run() {
	PATH="$library:$PATH" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" DYLD_LIBRARY_PATH="$library${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$@" 2>&1
}
fail() {
	echo "FAIL: $1" >&2
	printf '%s\n' "$2" >&2
	exit 1
}
# The 1000 blocks of 4096 bytes, untyped and without pointers, as one entry of at least their size.
known() {
	awk -v label="$1" '$1 == "census" && $2 == label && $3 == "type" && $NF == "(noptr)" && $6 >= 1000 && $4 >= 3.9 { found = 1 } END { exit !found }'
}
out=$(run "$census" 0)
known known <<<"$out" || fail "hl_gc_census did not report the known blocks" "$out"
grep -q "^census known class .* live " <<<"$out" || fail "hl_gc_census printed no size classes" "$out"
grep -q "^census known total mapped" <<<"$out" || fail "hl_gc_census printed no totals" "$out"
out=$(HL_GC_CENSUS_AT=1 run "$census" 1)
known gc1 <<<"$out" || fail "HL_GC_CENSUS_AT=1 did not report the known blocks at the first collection" "$out"
out=$(HL_GC_CENSUS_NOGC=1 run "$census" 0)
grep -q "^census known pages rss" <<<"$out" || fail "HL_GC_CENSUS_NOGC printed no page counts" "$out"
if grep -q "type" <<<"$out"; then fail "HL_GC_CENSUS_NOGC walked the heap" "$out"; fi
out=$(run "$census" 1)
if grep -q "^census" <<<"$out"; then fail "a collection printed a census without HL_GC_CENSUS_AT" "$out"; fi
echo "PASS: heap census reports a known allocation, at a collection and without collecting, and is silent unless asked"
