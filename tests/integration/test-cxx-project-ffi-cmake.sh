#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
home=${HAXEON_HOME:-$repo_dir}
haxe=${HAXEON_HAXE:-"$home/.tools/haxe/haxe"}
project_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-cxx-project-cmake.XXXXXX")
trap 'rm -rf -- "$project_dir"' EXIT

case "$(uname -s)" in
	Darwin)
		ffi_suffix=".dylib"
		cmake_import_archive=""
		;;
	MINGW*|MSYS*|CYGWIN*)
		ffi_suffix=".dll"
		if command -v cl.exe >/dev/null 2>&1 || command -v cl >/dev/null 2>&1; then
			cmake_import_archive="$project_dir/app/build/host/native/foo/foo.lib"
		else
			cmake_import_archive="$project_dir/app/build/host/native/foo/libfoo.dll.a"
		fi
		;;
	*)
		ffi_suffix=".so"
		cmake_import_archive=""
		;;
esac

if [[ ! -x "$haxe" ]]; then
	echo "missing Haxe executable: $haxe" >&2
	exit 1
fi

mkdir -p "$project_dir/app/src" "$project_dir/foo/src" "$project_dir/foo/ffi" "$project_dir/foo/native"
cp "$repo_dir/tests/ffi/cxx_thunk_fixture.hpp" "$project_dir/foo/native/cxx_thunk_fixture.hpp"
cp "$repo_dir/tests/ffi/cxx_thunk_fixture.cpp" "$project_dir/foo/native/cxx_thunk_fixture.cpp"
cp "$repo_dir/tests/ffi/cxx_owned_cmake_fixture.hpp" "$project_dir/foo/native/cxx_owned_cmake_fixture.hpp"
cp "$repo_dir/tests/ffi/cxx_owned_cmake_fixture.cpp" "$project_dir/foo/native/cxx_owned_cmake_fixture.cpp"
cp "$repo_dir/tests/ffi/cxx_cmake_fixture.hpp" "$project_dir/foo/native/cxx_cmake_fixture.hpp"

cat > "$project_dir/foo/haxeon.json" <<'JSON'
{
  "version": 1,
  "package": { "name": "foo" },
  "sourceRoots": ["src"],
  "native": {
    "cmake": { "source": "native", "target": "foo" }
  },
  "ffi": { "imports": ["ffi/cxx_thunk_project.ffi.json"] }
}
JSON
cat > "$project_dir/foo/native/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.16)
project(foo LANGUAGES CXX)
add_library(foo SHARED cxx_thunk_fixture.cpp cxx_owned_cmake_fixture.cpp)
set_target_properties(foo PROPERTIES
  PREFIX ""
  OUTPUT_NAME "foo"
  SUFFIX ".hdll"
  LIBRARY_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}"
  RUNTIME_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}"
  ARCHIVE_OUTPUT_DIRECTORY "${HAXEON_NATIVE_OUTPUT_DIR}"
)
CMAKE
cat > "$project_dir/foo/ffi/cxx_thunk_project.ffi.json" <<'JSON'
{
  "version": 1,
  "name": "cxx-cmake-thunk-project",
  "language": "c++",
  "header": "../native/cxx_cmake_fixture.hpp",
  "includes": ["../native"],
  "std": "c++20",
  "library": "foo",
  "interface": "CxxCmakeThunkProject",
  "select": [
    "cxxthunk::Counter::value",
    "cxxthunk::Counter::fail",
    "cxxthunk::acquire",
    "cxxthunk::apply",
    "cxxthunk::set_handler",
    "cxxthunk::clear_handler",
    "cxxthunk::fire_handler",
    "cxxthunk::BinaryCallback",
    "cxxthunk::add",
    "cxxcmakeown::ManagedWidget::value",
    "cxxcmakeown::acquire_managed",
    "cxxcmakeown::released_managed"
  ],
  "cxxThunks": true,
  "cxxOwnership": {
    "cxxcmakeown::acquire_managed": "cxxcmakeown::release_managed"
  },
  "projection": true
}
JSON
cat > "$project_dir/app/haxeon.json" <<'JSON'
{
  "version": 1,
  "package": { "name": "app" },
  "entry": "Main",
  "sourceRoots": ["src"],
  "dependencies": { "foo": { "path": "../foo" } }
}
JSON
cat > "$project_dir/app/src/Main.hx" <<'HX'
import Counter;
import CxxCmakeThunkProject;
import CxxCmakeThunkProjectFunctions;

function main():Int {
	var counter = Counter.fromNative(CxxCmakeThunkProject.__cxx_cxxthunk__acquire()),
		methodFailed = false;
	try counter.fail() catch (error:Dynamic) methodFailed = Std.string(error).indexOf("counter failed") >= 0;
	var functionWorked = CxxCmakeThunkProjectFunctions.add(20, 22) == 42,
		functionFailed = false;
	try CxxCmakeThunkProjectFunctions.add(1, 0) catch (error:Dynamic) functionFailed = Std.string(error).indexOf("division-like failure") >= 0;
	var callback = new __cxx_cxxthunk__BinaryCallbackCallback(function(left:Int, right:Int) return left + right),
		callbackWorked = CxxCmakeThunkProject.__cxx_cxxthunk__apply(callback, 20, 22) == 42;
	CxxCmakeThunkProject.__cxx_cxxthunk__set_handler(callback);
	var retainedWorked = CxxCmakeThunkProject.__cxx_cxxthunk__fire_handler(21) == 42;
	CxxCmakeThunkProject.__cxx_cxxthunk__clear_handler();
	callback.close();
	var owner = CxxCmakeThunkProjectFunctions.acquire_managed(),
		managed = owner.borrow(),
		managedWorked = managed.value() == 7,
		firstClose = owner.close(),
		secondClose = owner.close(),
		ownershipWorked = managedWorked && firstClose && !secondClose && owner.isClosed()
			&& CxxCmakeThunkProject.__cxx_cxxcmakeown__released_managed() == 1;
	return counter.value() == 42 && methodFailed && functionWorked && functionFailed && callbackWorked && retainedWorked && ownershipWorked ? 42 : 1;
}
HX

run_cli() {
	HAXEON_HOME="$home" HAXEON_COMPILER_SOURCE="$repo_dir/src" "$haxe" --cwd "$repo_dir" -cp "$repo_dir/src" --run tools.HaxeonCli "$@"
}

first_output=$(run_cli build --project "$project_dir/app/haxeon.json")
[[ "$first_output" == *"Configure CMake package foo"* ]]
[[ "$first_output" == *"Build CMake target foo"* ]]
[[ "$first_output" == *"Compile C++"* ]]
[[ "$first_output" == *"Link shared library foo FFI cxx-cmake-thunk-project"* ]]
test -s "$project_dir/app/build/host/native/foo/foo.hdll"
if [[ -n "$cmake_import_archive" ]]; then
	test -s "$cmake_import_archive"
fi
test -s "$project_dir/app/build/host/native/foo/libcxx-cmake-thunk-project$ffi_suffix"
test -s "$project_dir/app/build/host/native/foo/ffi/cxx-cmake-thunk-project/cxx-cmake-thunk-project-thunks.o"
test -s "$project_dir/app/build/host/native/foo/ffi/cxx-cmake-thunk-project/projection/OwnedManagedWidget.hx"
grep -q '@owned("haxeon_cxx_thunk_' "$project_dir/app/build/host/native/foo/ffi/cxx-cmake-thunk-project/cxx-cmake-thunk-project.hxi"
grep -q '__cxx_cxxthunk__set_handler(callback: __cxx_cxxthunk__BinaryCallback @retained)' "$project_dir/app/build/host/native/foo/ffi/cxx-cmake-thunk-project/cxx-cmake-thunk-project.hxi"
grep -q 'return OwnedManagedWidget.adopt' "$project_dir/app/build/host/native/foo/ffi/cxx-cmake-thunk-project/projection/CxxCmakeThunkProjectFunctions.hx"

set +e
run_cli run --project "$project_dir/app/haxeon.json"
run_status=$?
set -e
if [[ $run_status -ne 42 ]]; then
	echo "expected CMake-backed C++ thunk program to return 42, got $run_status" >&2
	exit 1
fi

second_output=$(run_cli build --project "$project_dir/app/haxeon.json")
[[ "$second_output" == *"native-cmake-build:foo"*"clean (fingerprint match)"* ]]
[[ "$second_output" == *"native-link:foo:FfiNativeSharedLibrary"*"clean (fingerprint match)"* ]]

printf '\n// invalidate the CMake-backed C++ thunk import\n' >> "$project_dir/foo/native/cxx_thunk_fixture.hpp"
changed_output=$(run_cli build --project "$project_dir/app/haxeon.json")
[[ "$changed_output" == *"Import c++ FFI cxx-cmake-thunk-project"* ]]
[[ "$changed_output" == *"Compile C++"* ]]
[[ "$changed_output" == *"Link shared library foo FFI cxx-cmake-thunk-project"* ]]

echo "PASS: CMake-backed project C++ thunk generation, ownership, linking, runtime errors, caching, and invalidation"
