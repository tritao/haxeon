#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/../.." && pwd)
project_dir="$root_dir/tests/fixtures/world-native-record-probe"
cache_dir="$root_dir/out/world-e1022/cache"

mkdir -p "$cache_dir"
mkdir -p "$root_dir/out/world-e1022"
export HAXEON_COMPILER_SESSION_DIR="$cache_dir/compiler-session"
export HAXEON_SOURCE_CACHE="$cache_dir/sources"
export HAXEON_DISABLE_ARTIFACT_CACHE=1
export HAXEON_COMPILER_SERVER=0
export HAXEON_CCACHE=0

cc -std=c11 -c "$project_dir/layout-oracle.c" -o "$root_dir/out/world-e1022/layout-oracle.o"
"$root_dir/scripts/haxeon" build --project="$project_dir/haxeon.json"
run_status=0
"$root_dir/scripts/haxeon" run --project="$project_dir/haxeon.json" || run_status=$?
if [[ $run_status -ne 42 ]]; then
	echo "Expected native record layout checks to return 42, got $run_status" >&2
	exit 1
fi
