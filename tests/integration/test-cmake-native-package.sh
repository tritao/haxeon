#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
home=${HAXEON_HOME:-$repo_dir}
haxe=${HAXEON_HAXE:-"$home/.tools/haxe/haxe"}
project_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-cmake-package.XXXXXX")
trap 'rm -rf -- "$project_dir"' EXIT

if [[ ! -x "$haxe" ]]; then
	echo "missing Haxe executable: $haxe" >&2
	exit 1
fi

mkdir -p "$project_dir/app/src" "$project_dir/foo/src" "$project_dir/foo/native"
printf '%s\n' '{"version":1,"package":{"name":"foo"},"sourceRoots":["src"],"native":{"cmake":{"source":"native","target":"foo"}}}' > "$project_dir/foo/haxeon.json"
printf '%s\n' 'cmake_minimum_required(VERSION 3.16)' 'project(foo C)' 'add_library(foo SHARED foo.c)' 'set_target_properties(foo PROPERTIES PREFIX "" OUTPUT_NAME "foo" SUFFIX ".hdll" LIBRARY_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}" RUNTIME_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}")' > "$project_dir/foo/native/CMakeLists.txt"
printf '%s\n' 'int foo_value(void) {' '    return 42;' '}' > "$project_dir/foo/native/foo.c"
printf '%s\n' '{"version":1,"package":{"name":"app"},"entry":"Main","sourceRoots":["src"],"dependencies":{"foo":{"path":"../foo"}}}' > "$project_dir/app/haxeon.json"
printf '%s\n' 'package app;' '' 'function main():Int' '    return 0;' > "$project_dir/app/src/Main.hx"

run_cli() {
	HAXEON_HOME="$home" HAXEON_COMPILER_SOURCE="$repo_dir/src" "$haxe" --cwd "$repo_dir" -cp "$repo_dir/src" --run tools.HaxeonCli "$@"
}

plan_output=$(run_cli build --project "$project_dir/app/haxeon.json" --plan)
[[ "$plan_output" == *"Configure CMake package foo"* ]]
[[ "$plan_output" == *"Build CMake target foo"* ]]
[[ "$plan_output" == *"foo:NativeSharedLibrary"* ]]
run_cli build --project "$project_dir/app/haxeon.json"
test -s "$project_dir/app/build/host/native/foo/foo.hdll"
second_output=$(run_cli build --project "$project_dir/app/haxeon.json")
[[ "$second_output" == *"native-cmake-configure:foo"*"clean (fingerprint match)"* ]]
[[ "$second_output" == *"Built target foo"* ]]
[[ "$second_output" == *"compile-project:"*"clean (fingerprint match)"* ]]
# CMake owns implementation/header dependencies, even without native.cmake.inputs.
printf '%s\n' '#define VALUE 43' > "$project_dir/foo/native/value.h"
printf '%s\n' '#include "value.h"' 'int foo_value(void) { return VALUE; }' > "$project_dir/foo/native/foo.c"
changed_output=$(run_cli build --project "$project_dir/app/haxeon.json")
[[ "$changed_output" == *"compile-project:"*"clean (fingerprint match)"* ]]
python3 - "$project_dir/app/build/host/native/foo/foo.hdll" <<'PYTEST'
import ctypes, sys
assert ctypes.CDLL(sys.argv[1]).foo_value() == 43
PYTEST
printf '%s\n' '#define VALUE 47' > "$project_dir/foo/native/value.h"
run_cli build --project "$project_dir/app/haxeon.json"
python3 - "$project_dir/app/build/host/native/foo/foo.hdll" <<'PYTEST'
import ctypes, sys
assert ctypes.CDLL(sys.argv[1]).foo_value() == 47
PYTEST
rm "$project_dir/app/build/host/native/foo/foo.hdll"
run_cli build --project "$project_dir/app/haxeon.json"
test -s "$project_dir/app/build/host/native/foo/foo.hdll"

echo "PASS: CMake native provider configures and builds a coarse package target"
