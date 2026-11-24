#!/usr/bin/env bash
set -euo pipefail

if [[ -n ${NKGPU_SHADER_TOOL:-} ]]; then
    printf '%s\n' "$NKGPU_SHADER_TOOL"
    exit 0
fi

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build="$root/out/nativekit-shaders"
cmake -S "$root/vendor/nativekit/modules/gpu/tools" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release >&2
cmake --build "$build" --target nkgpu-shaders >&2
tool="$build/nkgpu-shaders"
[[ -x "$tool" ]] || tool="$tool.exe"
printf '%s\n' "$tool"
