#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$repo_dir/out"

"$repo_dir/scripts/build-native.sh"

"$repo_dir/.tools/haxe/haxe" "$repo_dir/tests/hxml/hot-reload-test.hxml"
cmake --build --preset "${HAXEON_CMAKE_PRESET:-release}" --target haxeon-jit-support-lifetime
(
  cd "$repo_dir/out"
  LD_LIBRARY_PATH="$repo_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$repo_dir/.tools/hashlink/hl" hot-reload-test.hl
)
