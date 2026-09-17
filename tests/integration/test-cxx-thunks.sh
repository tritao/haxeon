#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$repo_dir/out/cxx_thunk_projection"

"$repo_dir/scripts/build-native.sh" >/dev/null
case "$(uname -s):$(uname -m)" in
	Linux:x86_64)
		target="x86_64-linux-gnu"
		;;
	Linux:aarch64|Linux:arm64)
		target="aarch64-linux-gnu"
		;;
	Darwin:x86_64)
		target="x86_64-apple-darwin"
		;;
	Darwin:arm64)
		target="arm64-apple-darwin"
		;;
	*)
		echo "unsupported host for C++ thunk integration test" >&2
		exit 1
		;;
esac

"$repo_dir/scripts/haxeon-ffi-import" \
	--language=c++ \
	--std=c++20 \
	--target="$target" \
	--cxx-thunks="$repo_dir/out/cxx_thunk_generated.cpp" \
	--library="$repo_dir/out/libcxx_thunk_fixture.so" \
	--interface=CxxThunkFixture \
	--haxe-output-dir="$repo_dir/out/cxx_thunk_projection" \
	--output="$repo_dir/out/cxx_thunk_fixture.hxi" \
	"$repo_dir/tests/ffi/cxx_thunk_fixture.hpp"

fixture_path=$(bash "$repo_dir/tests/integration/build-cxx-thunk-fixture.sh")
sed -i "s#${repo_dir}/out/libcxx_thunk_fixture.so#${fixture_path}#" "$repo_dir/out/cxx_thunk_fixture.hxi"
grep -q 'haxeon_cxx_thunk_last_error' "$repo_dir/out/cxx_thunk_generated.cpp"
grep -q 'C++ exception' "$repo_dir/out/cxx_thunk_projection/Counter.hx"
grep -q 'class CxxThunkFixtureFunctions' "$repo_dir/out/cxx_thunk_projection/CxxThunkFixtureFunctions.hx"

"$repo_dir/.tools/haxe/haxe" -cp "$repo_dir/src" -cp "$repo_dir/tests/runtime" --run CxxThunkMain \
	"$repo_dir/out/cxx-thunk-test.hl" "$repo_dir/out/cxx_thunk_fixture.hxi" "$repo_dir/out/cxx_thunk_projection/Counter.hx" \
	"$repo_dir/out/cxx_thunk_projection/CxxThunkFixtureFunctions.hx"
(
	cd "$repo_dir/out"
	set +e
	LD_LIBRARY_PATH="$repo_dir/out:$repo_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$repo_dir/.tools/hashlink/hl" cxx-thunk-test.hl
	status=$?
	set -e
	if [[ $status -ne 42 ]]; then
		echo "C++ thunk call returned $status, expected 42" >&2
		exit 1
	fi
)
