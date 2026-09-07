#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
expected_revision=a055e05e2e872ae12a32b53d0200612345059c38

if [[ ! -x "$haxe" ]]; then
	echo "missing local Haxe toolchain; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi
if [[ ! -f "$root_dir/vendor/utest/haxelib.json" ]]; then
	echo "missing vendor/utest; run git submodule update --init vendor/utest" >&2
	exit 1
fi
actual_revision=$(git -C "$root_dir/vendor/utest" rev-parse HEAD)
if [[ $actual_revision != "$expected_revision" ]]; then
	echo "vendor/utest revision mismatch: expected $expected_revision, got $actual_revision" >&2
	exit 1
fi

"$haxe" --cwd "$root_dir" -cp src -cp tests --run UtestUpstreamProbeMain
