#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$repo_dir/out"

"$repo_dir/scripts/build-native.sh"
fixture_path=$(bash "$repo_dir/tests/integration/build-cxx-hxi-fixture.sh")
hxi_path="$repo_dir/out/cxx_hxi_fixture.hxi"
projection_dir="$repo_dir/out/cxx_hxi_projection"

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
	MINGW*:x86_64|MSYS*:x86_64|CYGWIN*:x86_64)
		target="x86_64-w64-windows-gnu"
		;;
	*)
		echo "unsupported host for C++ HXI integration test" >&2
		exit 1
		;;
esac

"$repo_dir/scripts/haxeon-ffi-import" \
	--language=c++ \
	--std=c++20 \
	--target="$target" \
	--library="$fixture_path" \
	--interface=CxxFixture \
	--haxe-output-dir="$projection_dir" \
	--output="$hxi_path" \
	"$repo_dir/tests/ffi/cxx_runtime_fixture.hpp"

"$repo_dir/.tools/haxe/haxe" -cp "$repo_dir/src" -cp "$repo_dir/tests/runtime" --run CxxHxiCallMain \
	"$repo_dir/out/cxx-hxi-call-test.hl" "$hxi_path" "$projection_dir/DisplayList.hx"
(
	cd "$repo_dir/out"
	set +e
	LD_LIBRARY_PATH="$repo_dir/out:$repo_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$repo_dir/.tools/hashlink/hl" cxx-hxi-call-test.hl
	status=$?
	set -e
	if [[ $status -ne 42 ]]; then
		echo "C++ HXI call returned $status, expected 42" >&2
		exit 1
	fi
)
