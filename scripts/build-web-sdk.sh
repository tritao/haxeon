#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
nativekit="$root/vendor/nativekit"
build="$root/out/web-sdk"
destination="$root/out/sdk/platforms/web/ui"

EMSDK_QUIET=1 source "$nativekit/.tools/emsdk/emsdk_env.sh"
emcmake cmake -S "$root/packages/ui" -B "$build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DNK_BUILD_SHARED=OFF -DNK_BUILD_TESTS=OFF -DNK_BUILD_EXAMPLES=ON \
    -DNKUI_NATIVEKIT_DIR="$nativekit" -DNKUI_HAXEON_DIR="$root" \
    -DNKUI_HAXEON_SDK_HOST=ON -DNKUI_HAXEON_SUBSET_FONTS=OFF -DNK_SOKOL_BACKEND=gles3
cmake --build "$build" --target nativekit_ui_haxeon --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-2}"

mkdir -p "$destination"
cp "$build"/nativekit_ui_haxeon.{js,wasm} "$build/nativekit_haxeon_memory_contract.json" "$destination/"
cp -R "$build/assets" "$destination/"
{
    cat <<'NOTICE'
IBM Plex Sans and IBM Plex Sans JP: Copyright 2018 IBM Corp. All rights reserved.
IBM Plex Sans Arabic and IBM Plex Sans Hebrew: Copyright 2019 IBM Corp. All rights reserved.
Noto Emoji: Copyright 2013 Google LLC.

NOTICE
    cat "$root/packages/ui/vendor/nanovg/example/LICENSE_OFL.txt"
} >"$destination/assets/OFL.txt"
