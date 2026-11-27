#!/usr/bin/env bash
# Describes the API of the standard library and of each first-party package with haxeon doc, into
# site/generated/api/<directory>.json (standard-library.json for the standard library), which the reference's pages render
# (src/pages/reference/api). A package with no Haxe sources of its own is skipped. Prints each one's doc-comment coverage
# at the end.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
destination="$root/site/generated/api"
rm -rf "$destination"
mkdir -p "$destination"

echo "== standard library"
"$root/scripts/haxeon" doc --standard-library --output "$destination/standard-library.json"

for manifest in "$root"/packages/*/haxeon.json "$root"/packages/*/haxeon.toml; do
	[[ -f $manifest ]] || continue
	package=$(dirname "$manifest")
	name=$(basename "$package")
	if ! find "$package" -name '*.hx' -not -path '*/tests/*' -not -path '*/examples/*' -print -quit | grep -q .; then
		echo "== $name: no Haxe sources, skipped"
		continue
	fi
	echo "== $name"
	"$root/scripts/haxeon" doc --project "$manifest" --output "$destination/$name.json"
done

node "$root/site/scripts/api-coverage.mjs" "$destination"
