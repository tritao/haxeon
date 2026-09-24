#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
home=${HAXEON_HOME:-$repo_dir}
haxe=${HAXEON_HAXE:-"$home/.tools/haxe/haxe"}
project_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-native-package.XXXXXX")
trap 'rm -rf -- "$project_dir"' EXIT

if [[ ! -x "$haxe" ]]; then
	echo "missing Haxe executable: $haxe" >&2
	exit 1
fi

cp -R "$repo_dir/tests/fixtures/build/native-package/." "$project_dir/"

run_cli() {
	HAXEON_HOME="$home" HAXEON_COMPILER_SOURCE="$repo_dir/src" "$haxe" --cwd "$repo_dir" -cp "$repo_dir/src" --run tools.HaxeonCli "$@"
}

plan_output=$(run_cli build --project "$project_dir/app/haxeon.json" --plan --explain --timings)
[[ "$plan_output" == *"foo:NativeSharedLibrary"* ]]
[[ "$plan_output" != *"foo:NativeStaticLibrary"* ]]
[[ "$plan_output" == *"Compile C"* ]]
[[ "$plan_output" == *"Link shared library foo"* ]]
[[ "$plan_output" == *"Compile Haxe package"* ]]
[[ "$plan_output" == *"Build explanation:"* ]]
[[ "$plan_output" == *"inputs:"* && "$plan_output" == *"outputs:"* ]]
[[ "$plan_output" == *"Timings:"* ]]

run_cli build --project "$project_dir/app/haxeon.json" --jobs 4
test -s "$project_dir/app/build/host/main.hl"
test -s "$project_dir/app/build/host/native/foo/foo.hdll"
test -s "$project_dir/app/build/host/native/foo/foo.o"
test -s "$project_dir/app/build/host/native/foo/extra.o"

set +e
run_cli run --project "$project_dir/app/haxeon.json"
run_status=$?
set -e
if [[ $run_status -ne 42 ]]; then
	echo "expected native package program to return 42, got $run_status" >&2
	exit 1
fi

"$repo_dir/scripts/replace-in-file.sh" 's/return Foo.answer()/return Foo.answer() + 1/' "$project_dir/app/src/Main.hx"
haxe_edit_output=$(run_cli build --project "$project_dir/app/haxeon.json")
[[ "$haxe_edit_output" == *"native-compile:"*"clean (fingerprint match)"* ]]
[[ "$haxe_edit_output" == *"native-link:"*"clean (fingerprint match)"* ]]

"$repo_dir/scripts/replace-in-file.sh" 's/return FOO_ANSWER/return 41/' "$project_dir/foo/native/foo.c"
native_edit_output=$(run_cli build --project "$project_dir/app/haxeon.json")
[[ "$native_edit_output" == *"Compile C"* ]]
[[ "$native_edit_output" == *"native/foo.c] Compile C"* ]]
[[ "$native_edit_output" == *"native/extra.c] clean (fingerprint match)"* ]]
[[ "$native_edit_output" == *"Link shared library foo"* ]]

"$repo_dir/scripts/replace-in-file.sh" 's/return 41/return FOO_ANSWER/' "$project_dir/foo/native/foo.c"
"$repo_dir/scripts/replace-in-file.sh" 's/#define FOO_ANSWER 42/#define FOO_ANSWER 43/' "$project_dir/foo/native/include/foo.h"
header_edit_output=$(run_cli build --project "$project_dir/app/haxeon.json")
[[ "$header_edit_output" == *"native/foo.c] Compile C"* ]]
[[ "$header_edit_output" == *"native/extra.c] clean (fingerprint match)"* ]]
[[ "$header_edit_output" == *"Link shared library foo"* ]]

"$repo_dir/scripts/replace-in-file.sh" 's/return FOO_ANSWER/return (/' "$project_dir/foo/native/foo.c"
set +e
native_failure_output=$(run_cli build --project "$project_dir/app/haxeon.json" 2>&1)
native_failure_status=$?
set -e
if [[ $native_failure_status -eq 0 ]]; then
	echo "expected an invalid native source to fail the build" >&2
	exit 1
fi
[[ "$native_failure_output" == *"foo.c"* ]]
[[ "$native_failure_output" == *"error:"* ]]

echo "PASS: local Haxe and native package build, run, fingerprints, and compiler diagnostics"
