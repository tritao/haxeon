#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$repo_dir/out/cxx_string_view_projection"

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
		echo "unsupported host for C++ string_view integration test" >&2
		exit 1
		;;
esac

"$repo_dir/scripts/haxeon-ffi-import" \
	--language=c++ \
	--std=c++20 \
	--target="$target" \
	--cxx-thunks="$repo_dir/out/cxx_string_view_generated.cpp" \
	--library="$repo_dir/out/libcxx_string_view_fixture.so" \
	--interface=cxx_view \
	--haxe-output-dir="$repo_dir/out/cxx_string_view_projection" \
	--output="$repo_dir/out/cxx_string_view_fixture.hxi" \
	"$repo_dir/tests/ffi/cxx_string_view_fixture.hpp"

fixture_path=$(bash "$repo_dir/tests/integration/build-cxx-string-view-fixture.sh")
sed -i "s#${repo_dir}/out/libcxx_string_view_fixture.so#${fixture_path}#" "$repo_dir/out/cxx_string_view_fixture.hxi"
grep -q 'std::string_view(arg0, arg0__length)' "$repo_dir/out/cxx_string_view_generated.cpp"
grep -q 'public function count(value:String):Int' "$repo_dir/out/cxx_string_view_projection/Text.hx"
grep -q 'haxe.Int64.ofInt(__cxx_value_bytes_0.length)' "$repo_dir/out/cxx_string_view_projection/Text.hx"

"$repo_dir/.tools/haxe/haxe" -cp "$repo_dir/src" -cp "$repo_dir/tests/runtime" --run CxxStringViewMain \
	"$repo_dir/out/cxx-string-view-test.hl" "$repo_dir/out/cxx_string_view_fixture.hxi" "$repo_dir/out/cxx_string_view_projection/Text.hx" \
	"$repo_dir/out/cxx_string_view_projection/cxx_viewFunctions.hx"
(
	cd "$repo_dir/out"
	set +e
	LD_LIBRARY_PATH="$repo_dir/out:$repo_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$repo_dir/.tools/hashlink/hl" cxx-string-view-test.hl
	status=$?
	set -e
	if [[ $status -ne 42 ]]; then
		echo "C++ string_view call returned $status, expected 42" >&2
		exit 1
	fi
)
