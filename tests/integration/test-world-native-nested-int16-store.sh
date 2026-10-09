#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
project_dir="$repo_dir/tests/fixtures/world-native-nested-int16-store"
output_dir="$repo_dir/out/world-native-nested-int16-store/integration"
mkdir -p "$output_dir"

export HAXEON_DISABLE_ARTIFACT_CACHE=1
export HAXEON_COMPILER_SERVER=0
export HAXEON_CCACHE=0
export HAXEON_COMPILER_SESSION_DIR="$output_dir/compiler-session"
export HAXEON_SOURCE_CACHE="$output_dir/sources"

if ! "$repo_dir/scripts/haxeon" run --project="$project_dir/haxeon.json" >"$output_dir/run.log" 2>&1; then
	cat "$output_dir/run.log" >&2
	exit 1
fi

if ! grep -Fq "nested Int16 store left adjacent Int32 at 0" "$output_dir/run.log"; then
	cat "$output_dir/run.log" >&2
	echo "World native nested Int16 store did not preserve the adjacent Int32" >&2
	exit 1
fi

echo "PASS: World nested Int16 field store preserves its adjacent Int32"
