#!/usr/bin/env bash
set -eo pipefail

example_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(cd "$example_dir/../../../.." && pwd)
nativekit=${NATIVEKIT_DIR:-"$root/vendor/nativekit"}
build_dir=${CIRCUIT_RUN_WEB_BUILD_DIR:-"$example_dir/build/web"}
emsdk=${EMSDK:-"$nativekit/.tools/emsdk"}
if ! command -v emcmake >/dev/null; then
    source "$emsdk/emsdk_env.sh" >/dev/null
fi

emcmake cmake -S "$example_dir" -B "$build_dir" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DNATIVEKIT_DIR="$nativekit"
cmake --build "$build_dir" --target circuit_run_site
