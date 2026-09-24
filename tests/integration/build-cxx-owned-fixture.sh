#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
mkdir -p "$repo_dir/out"

cxx=${CXX:-c++}
case "$(uname -s)" in
	Darwin)
		output="$repo_dir/out/libcxx_owned_fixture.dylib"
		"$cxx" -std=c++20 -fPIC -dynamiclib "$repo_dir/tests/ffi/cxx_owned_fixture.cpp" "$repo_dir/out/cxx_owned_generated.cpp" -o "$output"
		;;
	MINGW*|MSYS*|CYGWIN*)
		output="$repo_dir/out/cxx_owned_fixture.dll"
		"$cxx" -std=c++20 -shared "$repo_dir/tests/ffi/cxx_owned_fixture.cpp" "$repo_dir/out/cxx_owned_generated.cpp" -o "$output"
		;;
	*)
		output="$repo_dir/out/libcxx_owned_fixture.so"
		"$cxx" -std=c++20 -fPIC -shared "$repo_dir/tests/ffi/cxx_owned_fixture.cpp" "$repo_dir/out/cxx_owned_generated.cpp" -o "$output"
		;;
esac

printf '%s\n' "$output"
