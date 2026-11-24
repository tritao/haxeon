#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
nativekit="$root/vendor/nativekit"
app="$root/packages/gpu/examples/circuit-run"
destination="$root/site/dist/gpu/circuit-run"

# The app links the SDK's WebGL2 host, which needs Emscripten to build.
if [[ ! -f "$root/out/sdk/platforms/web/ui/nativekit_haxeon_memory_contract.json" ]]; then
    if [[ ! -f "$nativekit/.tools/emsdk/emsdk_env.sh" ]]; then
        "$nativekit/tools/setup-web.sh"
    fi
    "$root/scripts/build-web-sdk.sh"
fi
(cd "$app" && "$root/scripts/haxeon" build --target wasm32 --jobs "${BUILD_JOBS:-2}")

rm -rf "$destination"
mkdir -p "$destination"
cp -R "$app/build/web/wasm32/." "$destination/"
