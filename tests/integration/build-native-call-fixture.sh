#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
source_file="$repo_dir/tests/native/native_call_fixture.c"

case "$(uname -s)" in
	Darwin)
		fixture_path="$repo_dir/out/libnative_call_fixture.dylib"
		cc -dynamiclib "$source_file" -o "$fixture_path"
		;;
	MINGW*|MSYS*|CYGWIN*)
		fixture_path="$repo_dir/out/native_call_fixture.dll"
		cc -shared "$source_file" -o "$fixture_path"
		;;
	*)
		fixture_path="$repo_dir/out/libnative_call_fixture.so"
		cc -shared -fPIC "$source_file" -o "$fixture_path"
		;;
esac

printf '%s\n' "$fixture_path"
