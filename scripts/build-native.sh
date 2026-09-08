#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
preset=${HAXEON_CMAKE_PRESET:-release}

cmake --preset "$preset" -S "$root_dir"
cmake --build --preset "$preset"
