#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
nativekit="$root/vendor/nativekit"
app="$root/packages/gpu/examples/circuit-run"
destination="$root/site/dist/gpu/circuit-run"

# The app links the SDK's WebGL2 host, which needs Emscripten. The host build is incremental, so it always runs: a host
# left from an earlier NativeKit would load but never present a frame.
if [[ ! -f "$nativekit/.tools/emsdk/emsdk_env.sh" ]]; then
    "$nativekit/tools/setup-web.sh"
fi
"$root/scripts/build-web-sdk.sh"
(cd "$app" && "$root/scripts/haxeon" build --target wasm32 --jobs "${BUILD_JOBS:-2}")

rm -rf "$destination"
mkdir -p "$destination"
cp -R "$app/build/web/wasm32/." "$destination/"
