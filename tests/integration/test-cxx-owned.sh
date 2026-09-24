#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
mkdir -p "$repo_dir/out/cxx_owned_projection"

case "$(uname -s):$(uname -m)" in
	Linux:x86_64) target="x86_64-linux-gnu"; library="$repo_dir/out/libcxx_owned_fixture.so" ;;
	Linux:aarch64|Linux:arm64) target="aarch64-linux-gnu"; library="$repo_dir/out/libcxx_owned_fixture.so" ;;
	Darwin:x86_64) target="x86_64-apple-darwin"; library="$repo_dir/out/libcxx_owned_fixture.dylib" ;;
	Darwin:arm64) target="arm64-apple-darwin"; library="$repo_dir/out/libcxx_owned_fixture.dylib" ;;
	MINGW*:x86_64|MSYS*:x86_64|CYGWIN*:x86_64) target="x86_64-w64-windows-gnu"; library="$repo_dir/out/cxx_owned_fixture.dll" ;;
	*) echo "unsupported host for C++ ownership integration test" >&2; exit 1 ;;
esac

"$repo_dir/scripts/build-native.sh"
manifest="$repo_dir/out/cxx_owned_fixture.ffi.json"
cat > "$manifest" <<JSON
{
  "version": 1,
  "name": "cxx-owned-fixture",
  "language": "c++",
  "header": "$repo_dir/tests/ffi/cxx_owned_fixture.hpp",
  "includes": ["$repo_dir/tests/ffi"],
  "std": "c++20",
  "library": "$library",
  "interface": "CxxOwnedFixture",
  "cxxThunks": true,
  "cxxOwnership": {
    "cxxown::acquire": "cxxown::release"
  },
  "projection": true
}
JSON
"$repo_dir/scripts/haxeon-ffi-import" \
	--manifest="$manifest" \
	--cxx-thunks="$repo_dir/out/cxx_owned_generated.cpp" \
	--target="$target" \
	--library="$library" \
	--interface=CxxOwnedFixture \
	--haxe-output-dir="$repo_dir/out/cxx_owned_projection" \
	--output="$repo_dir/out/cxx_owned_fixture.hxi" \
	"$repo_dir/tests/ffi/cxx_owned_fixture.hpp"

fixture_path=$(bash "$repo_dir/tests/integration/build-cxx-owned-fixture.sh")
[[ "$fixture_path" == "$library" ]]

grep -q 'OwnedWidget' "$repo_dir/out/cxx_owned_projection/CxxOwnedFixtureFunctions.hx"
grep -q '@owned("haxeon_cxx_thunk_' "$repo_dir/out/cxx_owned_fixture.hxi"
grep -q 'return OwnedWidget.adopt' "$repo_dir/out/cxx_owned_projection/CxxOwnedFixtureFunctions.hx"

"$repo_dir/.tools/haxe/haxe" -cp "$repo_dir/src" -cp "$repo_dir/tests/runtime" --run CxxOwnedMain \
	"$repo_dir/out/cxx-owned-test.hl" "$repo_dir/out/cxx_owned_fixture.hxi" "$repo_dir/out/cxx_owned_projection"
(
	cd "$repo_dir/out"
	set +e
	LD_LIBRARY_PATH="$repo_dir/out:$repo_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$repo_dir/.tools/hashlink/hl" cxx-owned-test.hl
	status=$?
	set -e
	if [[ $status -ne 42 ]]; then
		echo "C++ owned object call returned $status, expected 42" >&2
		exit 1
	fi
)

echo "PASS: explicit C++ factory ownership, release adapters, and closeable projections"
