#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$repo_dir/out"

"$repo_dir/scripts/build-native.sh"

"$repo_dir/.tools/haxe/haxe" "$repo_dir/tests/hxml/hot-reload-test.hxml" -hl "$repo_dir/out/hot-reload-test.hl"
cmake --build --preset "${HAXEON_CMAKE_PRESET:-release}" --target haxeon-jit-support-lifetime
hashlink_dir="$("$repo_dir/scripts/hashlink-path.sh")"
(
  cd "$repo_dir/out"
  # The test runs the JIT support helper built above from the HashLink directory it names.
  HAXEON_HASHLINK_DIR="$hashlink_dir" LD_LIBRARY_PATH="$hashlink_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$hashlink_dir/hl" hot-reload-test.hl
)
