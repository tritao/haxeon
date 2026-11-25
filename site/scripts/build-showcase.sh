#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ui="$root/packages/ui"
nativekit="$root/vendor/nativekit"
build="$root/out/site-showcase"
# Into the git-ignored public/, before the site build, which copies it to dist/ and shows the start button for it.
destination="$root/site/public/ui/showcase"

if [[ ! -f "$nativekit/.tools/emsdk/emsdk_env.sh" ]]; then
    "$nativekit/tools/setup-web.sh"
fi
EMSDK_QUIET=1 source "$nativekit/.tools/emsdk/emsdk_env.sh"
emcmake cmake -S "$ui" -B "$build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DNK_BUILD_SHARED=OFF -DNK_BUILD_TESTS=OFF -DNK_BUILD_EXAMPLES=ON \
    -DNKUI_NATIVEKIT_DIR="$nativekit" -DNKUI_HAXEON_DIR="$root" \
    -DNKUI_HAXEON_TARGET=wasm32 -DNK_SOKOL_BACKEND=gles3
# The NativeKit Packages workflow audits the checked-in Wasm bindings.
NATIVEKIT_HAXEON_SKIP_HXI_CHECK=1 cmake --build "$build" --target nativekit_ui_haxeon --parallel "${BUILD_JOBS:-2}"

rm -rf "$destination"
mkdir -p "$destination"
cp "$build/nativekit_ui_haxeon.html" "$destination/index.html"
cp "$build"/nativekit_ui_haxeon{.js,.wasm,_guest.wasm} "$build/haxeon-host.js" "$destination/"
cp -R "$build/assets" "$destination/"
