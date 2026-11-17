#!/usr/bin/env bash
# The checkout-built HashLink loads the debug sections it knows, skips unknown ones, and rejects a truncated section.
set -euo pipefail

source "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/env.sh"
haxeon_require_haxe
haxeon_require_hashlink
haxeon_export_library_path
hl="$("$haxeon_root/scripts/hashlink-path.sh")/hl"
out="$haxeon_suite_out/hlb-debug-sections"
mkdir -p "$out"
"$haxeon_haxe" --cwd "$haxeon_root" common.hxml -cp tests -cp tests/tooling --run DebugSectionFixture \
	"$out/valid.hl" "$out/malformed.hl"
"$hl" "$out/valid.hl"
if "$hl" "$out/malformed.hl" >"$out/malformed.stdout" 2>"$out/malformed.stderr"; then
	echo "HashLink accepted a truncated debug section" >&2
	exit 1
fi
echo "PASS: HLB debug sections: known metadata loads, unknown sections are skipped, truncated sections are rejected"
