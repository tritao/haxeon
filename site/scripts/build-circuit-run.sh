#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
nativekit="$root/vendor/nativekit"
build="$root/out/site-circuit-run"
destination="$root/site/dist/gpu/circuit-run"

if [[ ! -f "$nativekit/.tools/emsdk/emsdk_env.sh" ]]; then
    "$nativekit/tools/setup-web.sh"
fi
CIRCUIT_RUN_WEB_BUILD_DIR="$build" CMAKE_BUILD_PARALLEL_LEVEL="${BUILD_JOBS:-2}" \
    "$root/packages/gpu/examples/circuit-run/web/build.sh"

mkdir -p "$destination"
cp "$build"/{index.html,circuit_run.js,circuit_run.wasm,circuit_run.data,circuit_run_guest.wasm,haxeon-host.js,nativekit_haxeon_memory_contract.json} "$destination/"
