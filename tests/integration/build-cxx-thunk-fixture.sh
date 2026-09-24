#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
output="$repo_dir/out/libcxx_thunk_fixture.so"

case "$(uname -s)" in
	Linux)
		cxx="${CXX:-c++}"
		"$cxx" -std=c++20 -fPIC -shared "$repo_dir/tests/ffi/cxx_thunk_fixture.cpp" "$repo_dir/out/cxx_thunk_generated.cpp" -o "$output"
		;;
	Darwin)
		cxx="${CXX:-c++}"
		output="$repo_dir/out/libcxx_thunk_fixture.dylib"
		"$cxx" -std=c++20 -fPIC -dynamiclib "$repo_dir/tests/ffi/cxx_thunk_fixture.cpp" "$repo_dir/out/cxx_thunk_generated.cpp" -o "$output"
		;;
	*)
		echo "unsupported host for C++ thunk integration test" >&2
		exit 1
		;;
esac

echo "$output"
