#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$repo_dir/out"

"$repo_dir/scripts/build-runtime.sh"
cc -shared -fPIC "$repo_dir/tests/native/native_call_fixture.c" -o "$repo_dir/out/libnative_call_fixture.so"
"$repo_dir/.tools/haxe/haxe" "$repo_dir/tests/hxml/native-call-test.hxml"
(
	cd "$repo_dir/out"
	LD_LIBRARY_PATH="$repo_dir/out:$repo_dir/vendor/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$repo_dir/vendor/hashlink/hl" native-call-test.hl native_call_fixture
)
