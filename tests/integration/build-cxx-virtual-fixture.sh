#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
output="$repo_dir/out/libcxx_virtual_fixture.so"

case "$(uname -s)" in
	Linux*)
		cxx="${CXX:-c++}"
		"$cxx" -std=c++20 -fPIC -shared "$repo_dir/tests/ffi/cxx_virtual_fixture.cpp" -o "$output"
		;;
	Darwin*)
		cxx="${CXX:-c++}"
		"$cxx" -std=c++20 -fPIC -dynamiclib "$repo_dir/tests/ffi/cxx_virtual_fixture.cpp" -o "$output"
		;;
	*)
		echo "unsupported host for C++ virtual fixture" >&2
		exit 1
		;;
esac

printf '%s\n' "$output"
