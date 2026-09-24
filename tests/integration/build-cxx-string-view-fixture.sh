#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
output="$repo_dir/out/libcxx_string_view_fixture.so"

case "$(uname -s)" in
	Linux)
		cxx="${CXX:-c++}"
		"$cxx" -std=c++20 -fPIC -shared "$repo_dir/tests/ffi/cxx_string_view_fixture.cpp" "$repo_dir/out/cxx_string_view_generated.cpp" -o "$output"
		;;
	Darwin)
		cxx="${CXX:-c++}"
		output="$repo_dir/out/libcxx_string_view_fixture.dylib"
		"$cxx" -std=c++20 -fPIC -dynamiclib "$repo_dir/tests/ffi/cxx_string_view_fixture.cpp" "$repo_dir/out/cxx_string_view_generated.cpp" -o "$output"
		;;
	*)
		echo "unsupported host for C++ string_view integration test" >&2
		exit 1
		;;
esac

echo "$output"
