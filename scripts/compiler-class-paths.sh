#!/usr/bin/env bash
# The class paths of the compiler's own sources, as absolute paths, from common.hxml: the one list every stock-Haxe build of them uses.
# For tools outside this tree (the editor, kit scripts) that build, run, hash or watch those sources.
#
#   scripts/compiler-class-paths.sh            one path per line (for `find`, hashing, `-newer` checks)
#   scripts/compiler-class-paths.sh --cp-args  "-cp" and the path on alternate lines (mapfile -t into a Haxe argument array)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
listing="$root/common.hxml"
[[ -f $listing ]] || { echo "$root has no common.hxml, which lists the class paths of its compiler sources" >&2; exit 1; }
found=0
while IFS= read -r line; do
	case $line in
	"-cp "*)
		found=1
		path="$root/${line#-cp }"
		if [[ ${1:-} == --cp-args ]]; then printf '%s\n%s\n' -cp "$path"; else printf '%s\n' "$path"; fi
		;;
	esac
done <"$listing"
[[ $found == 1 ]] || { echo "common.hxml lists no class path" >&2; exit 1; }
