#!/usr/bin/env bash
set -euo pipefail

# Type-checks the projects that consume this compiler when this checkout sits inside a Materia checkout.
# A stricter compiler rule (null flow, conversions) can reject code in those projects that no compiler fixture covers;
# run this after changing typing or flow analysis and before moving the submodule pointer.
root_dir=$(cd "$(dirname "$0")/.." && pwd)
parent_dir=$(cd "$root_dir/.." && pwd)
status=0
checked=0

for project in "$parent_dir/app/haxeon.json"; do
	[[ -f "$project" ]] || continue
	checked=$((checked + 1))
	echo "Type-checking $project"
	"$root_dir/scripts/haxeon" build --project "$project" --compiler-only || status=1
done

if [[ "$checked" -eq 0 ]]; then
	echo "no dependent projects next to this checkout; nothing to check"
fi
exit "$status"
