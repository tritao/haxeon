#!/usr/bin/env bash
# Every module of the standard library and of each first-party package type-checks, not only what a test, an example or the
# site reaches: `haxeon doc` types a library's own modules without an entry, as the site's API build does. Widgets nothing else
# compiled once stayed broken on main until that build ran. The host target only: most packages bind NativeKit, which has no
# Wasm build, and ui-showcase builds ui for the web. The pre-push hook runs it too (scripts/hooks/pre-push).
set -euo pipefail
source "$(dirname "$0")/../../scripts/lib/env.sh"

work="$haxeon_suite_out/package-modules"
mkdir -p "$work"
status=0
checked=0

check() {
	local name=$1
	shift
	if "$haxeon_root/scripts/haxeon" doc "$@" --diagnostic-format short --output "$work/$name.json" > "$work/$name.log" 2>&1; then
		checked=$((checked + 1))
	else
		cat "$work/$name.log" >&2
		echo "FAIL: a module of $name does not type-check; log: $work/$name.log" >&2
		status=1
	fi
}

check standard-library --standard-library
for manifest in "$haxeon_root"/packages/*/haxeon.json "$haxeon_root"/packages/*/haxeon.toml; do
	[[ -f $manifest ]] || continue
	package=$(dirname "$manifest")
	# A package whose Haxe sources are all tests or examples has no modules of its own to check.
	find "$package" -name '*.hx' -not -path '*/tests/*' -not -path '*/examples/*' -print -quit | grep -q . || continue
	check "$(basename "$package")" --project "$manifest"
done

[[ $status == 0 ]] && echo "PASS: every module of the standard library and of $((checked - 1)) packages type-checks"
exit "$status"
