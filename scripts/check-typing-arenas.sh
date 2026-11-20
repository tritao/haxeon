#!/usr/bin/env bash
# The escape check of the typing arenas (docs/design/ARENAS.md): builds the compiler with Haxeon (arenas do nothing in a
# stock-Haxe build), compiles it again with it, once plainly and once typing each class in an arena of its own, and fails
# when an arena is kept or the two outputs differ. A kept arena's references are printed by holder and allocation site.
#   scripts/check-typing-arenas.sh [--strict]   --strict: no evacuating release (every leftover placed by the code)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mode=check
[[ ${1:-} == --strict ]] && mode=strict
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-typing-arenas.XXXXXX")
trap 'rm -rf "$work"' EXIT
hl="$("$root/scripts/hashlink-path.sh")/hl"
export LD_LIBRARY_PATH="$root/out:$("$root/scripts/hashlink-path.sh")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cd "$root"
find src stdlib lib/haxeon-io -name '*.hx' | sort > "$work/sources.txt"
tool=$(scripts/haxeon dev tool-path compiler.tools.HaxeonCompiler | tail -1)
build() {
	"$hl" "$1" --build-mode=release --entry=compiler.tools.HaxeonCompiler --root=src --root=lib/haxeon-io --root=stdlib \
		--sources-file="$work/sources.txt" --output="$2" "${@:3}"
}
build "$tool" "$work/compiler.hl" > "$work/build.log" 2>&1 || { cat "$work/build.log"; exit 1; }
build "$work/compiler.hl" "$work/plain.hl" > "$work/plain.log" 2>&1 || { cat "$work/plain.log"; exit 1; }
if ! HL_GC_ARENA_SITES=1 build "$work/compiler.hl" "$work/arenas.hl" --typing-arenas=$mode > "$work/arenas.log" 2>&1; then
	grep -a "^HL arena reference" "$work/arenas.log" | sed 's/+[0-9]*//; s/ [0-9]* ->/ ->/' | sort | uniq -c | sort -rn | head -40
	grep -a "typing-arenas" "$work/arenas.log" >&2
	echo "FAIL: arenas typing classes were kept" >&2
	exit 1
fi
cmp -s "$work/plain.hl" "$work/arenas.hl" || { echo "FAIL: typing in arenas changed the output" >&2; exit 1; }
grep -a "^typing arenas:" "$work/arenas.log"
echo "PASS: every class typed in an arena of its own was released ($mode), and the output is unchanged"
