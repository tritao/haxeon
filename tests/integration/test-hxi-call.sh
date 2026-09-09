#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$repo_dir/out"

"$repo_dir/scripts/build-runtime.sh"
cc -shared -fPIC "$repo_dir/tests/native/native_call_fixture.c" -o "$repo_dir/out/libnative_call_fixture.so"
"$repo_dir/.tools/haxe/haxe" -cp "$repo_dir/src" -cp "$repo_dir/tests/runtime" --run HxiCallMain \
	"$repo_dir/out/hxi-call-test.hl" "$repo_dir/out/libnative_call_fixture.so"
(
	cd "$repo_dir/out"
	set +e
	LD_LIBRARY_PATH="$repo_dir/vendor/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$repo_dir/vendor/hashlink/hl" hxi-call-test.hl
	status=$?
	set -e
	if [[ $status -ne 42 ]]; then
		echo "HXI C call returned $status, expected 42" >&2
		exit 1
	fi
)
