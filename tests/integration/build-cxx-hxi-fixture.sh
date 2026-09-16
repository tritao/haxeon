#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
source_file="$repo_dir/tests/ffi/cxx_runtime_fixture.cpp"
mkdir -p "$repo_dir/out"

case "$(uname -s)" in
	Darwin)
		fixture_path="$repo_dir/out/libcxx_hxi_fixture.dylib"
		c++ -std=c++20 -dynamiclib "$source_file" -o "$fixture_path"
		;;
	MINGW*|MSYS*|CYGWIN*)
		fixture_path="$repo_dir/out/cxx_hxi_fixture.dll"
		c++ -std=c++20 -shared "$source_file" -o "$fixture_path"
		;;
	*)
		fixture_path="$repo_dir/out/libcxx_hxi_fixture.so"
		c++ -std=c++20 -shared -fPIC "$source_file" -o "$fixture_path"
		;;
esac

printf '%s\n' "$fixture_path"
