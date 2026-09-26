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
