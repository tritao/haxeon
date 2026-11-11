#!/usr/bin/env bash
# Fails when Haxe source under src/ or lib/ writes a NUL character as a literal ("\u0000", "\x00", "\0", String.fromCharCode(0)),
# unless the file is listed in nul-allowlist.txt. HashLink compares String map keys as C strings, so a key built with a NUL separator
# ends at the NUL and distinct keys compare equal (this broke the provider table's row keys once).
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
allow="$root/tests/integration/nul-allowlist.txt"
status=0
while IFS= read -r hit; do
	file=${hit%%:*}
	if ! grep -qxE "$file( .*)?" <(grep -v '^#' "$allow" | grep -v '^$'); then
		echo "NUL literal in $hit" >&2
		status=1
	fi
done < <(cd "$root" && grep -rnE '\\u0000|\\x00|\\0|fromCharCode\(0\)' src lib --include='*.hx' || true)
if [[ $status -ne 0 ]]; then
	echo "Use a separator other than NUL for map keys, or list the file with a reason in tests/integration/nul-allowlist.txt." >&2
fi
exit $status
