#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/../.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
hl="$root_dir/vendor/hashlink/hl"
out_dir="$root_dir/out/differential"

if [[ ! -x "$haxe" || ! -x "$hl" ]]; then
	echo "missing local toolchain; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

make -C "$root_dir/vendor/hashlink" -j2 libhl.so hl >/dev/null
mkdir -p "$out_dir"

run_case() {
	local name=$1
	local official_source="$root_dir/tests/differential/$name.official.hx"
	local realtime_source="$root_dir/tests/differential/$name.realtime.hx"
	local official_output="$out_dir/$name.official.hl"
	local realtime_output="$out_dir/$name.realtime.hl"
	local official_dir
	official_dir=$(mktemp -d "$out_dir/official.XXXXXX")
	trap 'rm -rf "$official_dir"' RETURN
	cp "$official_source" "$official_dir/Main.hx"

	"$haxe" -cp "$official_dir" -main Main -hl "$official_output"
	"$haxe" --cwd "$root_dir" -cp src --run Main "$realtime_source" "$realtime_output" >/dev/null

	set +e
	LD_LIBRARY_PATH="$root_dir/vendor/hashlink" "$hl" "$official_output" >/dev/null 2>&1
	local official_status=$?
	LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$realtime_output" >/dev/null 2>&1
	local realtime_status=$?
	set -e

	if [[ $official_status -ne $realtime_status ]]; then
		echo "$name: official=$official_status realtime=$realtime_status" >&2
		exit 1
	fi
	echo "PASS: $name official and realtime behavior agree (exit $official_status)"
}

run_case arithmetic
run_case fibonacci
run_case control-flow
run_case nullable
