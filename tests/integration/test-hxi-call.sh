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

invalid_output="$repo_dir/out/hxi-invalid-null.txt"
set +e
(
	cd "$repo_dir/out"
	LD_LIBRARY_PATH="$repo_dir/vendor/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$repo_dir/vendor/hashlink/hl" hxi-call-test.hl.invalid-null
) >"$invalid_output" 2>&1
invalid_status=$?
set -e
if [[ $invalid_status -eq 0 ]] || ! rg -q "Non-null ordinary C pointer result returned NULL" "$invalid_output"; then
	echo "non-null HXI pointer result accepted NULL or reported the wrong error" >&2
	cat "$invalid_output" >&2
	exit 1
fi

set +e
(
	cd "$repo_dir/out"
	LD_LIBRARY_PATH="$repo_dir/vendor/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$repo_dir/vendor/hashlink/hl" hxi-call-test.hl.invalid-length
) >"$invalid_output" 2>&1
invalid_status=$?
set -e
if [[ $invalid_status -eq 0 ]] || ! rg -q "exceeds the 256 MiB safety limit" "$invalid_output"; then
	echo "oversized HXI byte result was accepted or reported the wrong error" >&2
	cat "$invalid_output" >&2
	exit 1
fi

set +e
(
	cd "$repo_dir/out"
	LD_LIBRARY_PATH="$repo_dir/vendor/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$repo_dir/vendor/hashlink/hl" hxi-call-test.hl.invalid-index
) >"$invalid_output" 2>&1
invalid_status=$?
set -e
if [[ $invalid_status -eq 0 ]] || ! rg -q "HXI array index out of bounds" "$invalid_output"; then
	echo "out-of-bounds HXI array access was accepted or reported the wrong error" >&2
	cat "$invalid_output" >&2
	exit 1
fi

set +e
(
	cd "$repo_dir/out"
	LD_LIBRARY_PATH="$repo_dir/vendor/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$repo_dir/vendor/hashlink/hl" hxi-call-test.hl.closed-callback
) >"$invalid_output" 2>&1
invalid_status=$?
set -e
if [[ $invalid_status -eq 0 ]] || ! rg -q "Closed native callback argument" "$invalid_output"; then
	echo "closed HXI callback was accepted or reported the wrong error" >&2
	cat "$invalid_output" >&2
	exit 1
fi
