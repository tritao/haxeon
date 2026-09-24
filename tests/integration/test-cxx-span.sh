#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$repo_dir/out/cxx_span_projection"

"$repo_dir/scripts/build-native.sh" >/dev/null
case "$(uname -s):$(uname -m)" in
	Linux:x86_64)
		target="x86_64-linux-gnu"
		library_path="$repo_dir/out/libcxx_span_fixture.so"
		;;
	Linux:aarch64|Linux:arm64)
		target="aarch64-linux-gnu"
		library_path="$repo_dir/out/libcxx_span_fixture.so"
		;;
	Darwin:x86_64)
		target="x86_64-apple-darwin"
		library_path="$repo_dir/out/libcxx_span_fixture.dylib"
		;;
	Darwin:arm64)
		target="arm64-apple-darwin"
		library_path="$repo_dir/out/libcxx_span_fixture.dylib"
		;;
	*)
		echo "unsupported host for C++ span integration test" >&2
		exit 1
		;;
esac

"$repo_dir/scripts/haxeon-ffi-import" \
	--language=c++ \
	--std=c++20 \
	--target="$target" \
	--cxx-thunks="$repo_dir/out/cxx_span_generated.cpp" \
	--library="$library_path" \
	--interface=cxx_span \
	--haxe-output-dir="$repo_dir/out/cxx_span_projection" \
	--output="$repo_dir/out/cxx_span_fixture.hxi" \
	"$repo_dir/tests/ffi/cxx_span_fixture.hpp"

fixture_path=$(bash "$repo_dir/tests/integration/build-cxx-span-fixture.sh")
test "$fixture_path" = "$library_path"
grep -q 'std::span<const std::byte>(arg0, arg0__length)' "$repo_dir/out/cxx_span_generated.cpp"
grep -q 'std::span<const std::uint8_t>(arg0, arg0__length)' "$repo_dir/out/cxx_span_generated.cpp"
grep -q 'public function byteCount(value:haxe.io.Bytes):Int' "$repo_dir/out/cxx_span_projection/Buffer.hx"
grep -q 'haxe.Int64.ofInt(value.length)' "$repo_dir/out/cxx_span_projection/Buffer.hx"

"$repo_dir/.tools/haxe/haxe" -cp "$repo_dir/src" -cp "$repo_dir/tests/runtime" --run CxxSpanMain \
	"$repo_dir/out/cxx-span-test.hl" "$repo_dir/out/cxx_span_fixture.hxi" "$repo_dir/out/cxx_span_projection/Buffer.hx" \
	"$repo_dir/out/cxx_span_projection/cxx_spanFunctions.hx"
(
	cd "$repo_dir/out"
	set +e
	LD_LIBRARY_PATH="$repo_dir/out:$repo_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$repo_dir/.tools/hashlink/hl" cxx-span-test.hl
	status=$?
	set -e
	if [[ $status -ne 42 ]]; then
		echo "C++ span call returned $status, expected 42" >&2
		exit 1
	fi
)
