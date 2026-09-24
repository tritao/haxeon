#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
home=${HAXEON_HOME:-$repo_dir}
haxe=${HAXEON_HAXE:-"$home/.tools/haxe/haxe"}
cxx=${CXX:-c++}
project_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-cxx-project.XXXXXX")
trap 'rm -rf -- "$project_dir"' EXIT

if [[ ! -x "$haxe" ]]; then
	echo "missing Haxe executable: $haxe" >&2
	exit 1
fi

mkdir -p "$project_dir/ffi" "$project_dir/lib" "$project_dir/src"
cp "$repo_dir/tests/ffi/cxx_runtime_fixture.hpp" "$project_dir/ffi/cxx_runtime_fixture.hpp"
cp "$repo_dir/tests/ffi/cxx_runtime_fixture.cpp" "$project_dir/ffi/cxx_runtime_fixture.cpp"

case "$(uname -s)" in
	Darwin)
		library_path="$project_dir/lib/libcxx_project_fixture.dylib"
		"$cxx" -std=c++20 -dynamiclib "$project_dir/ffi/cxx_runtime_fixture.cpp" -o "$library_path"
		;;
	MINGW*|MSYS*|CYGWIN*)
		library_path="$project_dir/lib/cxx_project_fixture.dll"
		"$cxx" -std=c++20 -shared "$project_dir/ffi/cxx_runtime_fixture.cpp" -o "$library_path"
		;;
	*)
		library_path="$project_dir/lib/libcxx_project_fixture.so"
		"$cxx" -std=c++20 -shared -fPIC "$project_dir/ffi/cxx_runtime_fixture.cpp" -o "$library_path"
		;;
esac

cat > "$project_dir/haxeon.json" <<JSON
{
	"version": 1,
	"package": { "name": "app" },
	"entry": "Main",
	"sourceRoots": ["src"],
	"ffi": { "imports": ["ffi/cxx_project.ffi.json"] }
}
JSON
cat > "$project_dir/ffi/cxx_project.ffi.json" <<JSON
{
	"version": 1,
	"name": "cxx-project",
	"language": "c++",
	"profile": "direct",
	"header": "cxx_runtime_fixture.hpp",
	"includes": ["."],
	"std": "c++20",
	"library": "$library_path",
	"interface": "CxxProject",
	"select": [
		"nkui::DisplayList::reset",
		"nkui::DisplayList::size",
		"nkui::acquire_handler",
		"nkui::acquire"
	],
	"projection": true
}
JSON
cat > "$project_dir/src/Main.hx" <<'HX'
import CxxProject;
import DisplayList;

function main():Int {
	var list = DisplayList.fromNative(CxxProject.__cxx_nkui__acquire());
	list.reset();
	var callback = CxxProject.__cxx_nkui__acquire_handler(),
		callbackWorked = callback.call(20, 22) == 42;
	callback.close();
	return list.size() == 0 && callbackWorked ? 42 : 1;
}
HX

run_cli() {
	HAXEON_HOME="$home" HAXEON_COMPILER_SOURCE="$repo_dir/src" "$haxe" --cwd "$repo_dir" -cp "$repo_dir/src" --run tools.HaxeonCli "$@"
}

first_output=$(run_cli build --project "$project_dir/haxeon.json")
[[ "$first_output" == *"Import c++ FFI cxx-project"* ]]
[[ "$first_output" == *"Compile Haxe package"* ]]
test -s "$project_dir/build/host/native/app/ffi/cxx-project/cxx-project.hxi"
test -s "$project_dir/build/host/native/app/ffi/cxx-project/projection/DisplayList.hx"
test -s "$project_dir/build/host/native/app/ffi/cxx-project/projection.sources"
test ! -e "$project_dir/build/host/native/app/ffi/cxx-project/cxx-project-thunks.cpp"

test -s "$project_dir/build/host/main.hl"
set +e
run_cli run --project "$project_dir/haxeon.json"
run_status=$?
set -e
if [[ $run_status -ne 42 ]]; then
	echo "expected C++ project FFI program to return 42, got $run_status" >&2
	exit 1
fi

second_output=$(run_cli build --project "$project_dir/haxeon.json")
[[ "$second_output" == *"ffi-import:"*"clean (fingerprint match)"* ]]

printf '\n// invalidate the project FFI import\n' >> "$project_dir/ffi/cxx_runtime_fixture.hpp"
changed_output=$(run_cli build --project "$project_dir/haxeon.json")
[[ "$changed_output" == *"Import c++ FFI cxx-project"* ]]
[[ "$changed_output" != *"ffi-import:"*"clean (fingerprint match)"* ]]

echo "PASS: project C++ FFI build, projection, runtime call, caching, and header invalidation"
