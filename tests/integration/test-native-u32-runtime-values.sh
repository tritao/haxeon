#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/../.." && pwd)
project="$root_dir/tests/fixtures/native-u32-runtime-values/haxeon.json"
build_root="$root_dir/out/native-u32-runtime-values"

export HAXEON_COMPILER_SESSION_DIR="$build_root/compiler-session"
export HAXEON_SOURCE_CACHE="$build_root/sources"
export HAXEON_DISABLE_ARTIFACT_CACHE=1
export HAXEON_COMPILER_SERVER=0
export HAXEON_CCACHE=0

"$root_dir/scripts/haxeon" build --project="$project"
run_status=0
"$root_dir/scripts/haxeon" run --project="$project" || run_status=$?
if [[ $run_status -ne 42 ]]; then
	echo "Expected UInt32 runtime value checks to return 42, got $run_status" >&2
	exit 1
fi
