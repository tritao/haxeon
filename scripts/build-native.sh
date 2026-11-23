#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
preset=${HAXEON_CMAKE_PRESET:-release}

# scripts/test.sh builds the native runtime once, then sets HAXEON_NATIVE_READY so the scripts
# it runs skip reconfiguring the shared build tree (concurrent cmake runs in one tree race).
if [[ ${HAXEON_NATIVE_READY:-0} == 1 ]]; then
	exit 0
fi

cmake --preset "$preset" -S "$root_dir"
cmake --build --preset "$preset"

# The browser host is built once for this SDK, independently of the desktop target.
if [[ -f "$root_dir/vendor/nativekit/.tools/emsdk/emsdk_env.sh" ]]; then
	bash "$root_dir/scripts/build-web-sdk.sh"
fi
