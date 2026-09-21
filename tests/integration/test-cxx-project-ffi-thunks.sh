#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
home=${HAXEON_HOME:-$repo_dir}
haxe=${HAXEON_HAXE:-"$home/.tools/haxe/haxe"}
cxx=${CXX:-c++}
project_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-cxx-project-thunks.XXXXXX")
trap 'rm -rf -- "$project_dir"' EXIT

if [[ ! -x "$haxe" ]]; then
	echo "missing Haxe executable: $haxe" >&2
	exit 1
fi

mkdir -p "$project_dir/ffi" "$project_dir/native" "$project_dir/src"
cp "$repo_dir/tests/ffi/cxx_thunk_fixture.hpp" "$project_dir/ffi/cxx_thunk_fixture.hpp"
cp "$repo_dir/tests/ffi/cxx_thunk_fixture.cpp" "$project_dir/native/cxx_thunk_fixture.cpp"

cat > "$project_dir/haxeon.json" <<'JSON'
{
  "version": 1,
  "package": { "name": "app" },
  "entry": "Main",
  "sourceRoots": ["src"],
  "native": {
    "sources": ["native/cxx_thunk_fixture.cpp"],
    "includeDirs": ["ffi"],
    "std": "c++20"
  },
  "ffi": { "imports": ["ffi/cxx_thunk_project.ffi.json"] }
}
JSON
cat > "$project_dir/ffi/cxx_thunk_project.ffi.json" <<'JSON'
{
  "version": 1,
  "name": "cxx-thunk-project",
  "language": "c++",
  "header": "cxx_thunk_fixture.hpp",
  "includes": ["."],
  "std": "c++20",
  "library": "app",
  "interface": "CxxThunkProject",
  "select": [
    "cxxthunk::Counter::value",
    "cxxthunk::Counter::fail",
    "cxxthunk::acquire",
    "cxxthunk::add"
  ],
  "cxxThunks": true,
  "projection": true
}
JSON
cat > "$project_dir/src/Main.hx" <<'HX'
import Counter;
import CxxThunkProject;
import CxxThunkProjectFunctions;

function main():Int {
	var counter = Counter.fromNative(CxxThunkProject.__cxx_cxxthunk__acquire()),
		methodFailed = false;
	try counter.fail() catch (error:Dynamic) methodFailed = Std.string(error).indexOf("counter failed") >= 0;
	var functionWorked = CxxThunkProjectFunctions.add(20, 22) == 42,
		functionFailed = false;
	try CxxThunkProjectFunctions.add(1, 0) catch (error:Dynamic) functionFailed = Std.string(error).indexOf("division-like failure") >= 0;
	return counter.value() == 42 && methodFailed && functionWorked && functionFailed ? 42 : 1;
}
HX

run_cli() {
	HAXEON_HOME="$home" HAXEON_COMPILER_SOURCE="$repo_dir/src" "$haxe" --cwd "$repo_dir" -cp "$repo_dir/src" --run tools.HaxeonCli "$@"
}

first_output=$(run_cli build --project "$project_dir/haxeon.json")
[[ "$first_output" == *"Import c++ FFI cxx-thunk-project"* ]]
[[ "$first_output" == *"Compile C++"* ]]
[[ "$first_output" == *"Link shared library app"* ]]
test -s "$project_dir/build/host/native/app/ffi/cxx-thunk-project/cxx-thunk-project.hxi"
test -s "$project_dir/build/host/native/app/ffi/cxx-thunk-project/cxx-thunk-project-thunks.cpp"
test -s "$project_dir/build/host/native/app/ffi/cxx-thunk-project/cxx-thunk-project-thunks.o"
test -s "$project_dir/build/host/native/app/libcxx-thunk-project.so"
test -s "$project_dir/build/host/native/app/app.hdll"
test -s "$project_dir/build/host/native/app/ffi/cxx-thunk-project/projection/Counter.hx"
test -s "$project_dir/build/host/native/app/ffi/cxx-thunk-project/projection/CxxThunkProjectFunctions.hx"
grep -q 'haxeon_cxx_thunk_last_error' "$project_dir/build/host/native/app/ffi/cxx-thunk-project/cxx-thunk-project-thunks.cpp"

set +e
run_cli run --project "$project_dir/haxeon.json"
run_status=$?
set -e
if [[ $run_status -ne 42 ]]; then
	echo "expected project C++ thunk program to return 42, got $run_status" >&2
	exit 1
fi

second_output=$(run_cli build --project "$project_dir/haxeon.json")
[[ "$second_output" == *"ffi-import:"*"clean (fingerprint match)"* ]]
[[ "$second_output" == *"native-compile:"*"clean (fingerprint match)"* ]]
[[ "$second_output" == *"native-link:"*"clean (fingerprint match)"* ]]

printf '\n// invalidate the project C++ thunk import\n' >> "$project_dir/ffi/cxx_thunk_fixture.hpp"
changed_output=$(run_cli build --project "$project_dir/haxeon.json")
[[ "$changed_output" == *"Import c++ FFI cxx-thunk-project"* ]]
[[ "$changed_output" == *"Compile C++"* ]]
[[ "$changed_output" == *"Link shared library app"* ]]

echo "PASS: project C++ thunk generation, native compilation, runtime errors, caching, and invalidation"
