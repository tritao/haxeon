#!/usr/bin/env bash
set -euo pipefail
package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
haxeon_dir="$(cd "$package_dir/../.." && pwd)"
nativekit_dir="$haxeon_dir/vendor/nativekit"
output="$package_dir/bindings/nativekit-audio-wasm.hxi"
destination="$output"
if [[ ${1:-} == --check ]]; then
  destination=$(mktemp)
  trap 'rm -f -- "$destination"' EXIT
elif [[ $# != 0 ]]; then
  echo 'usage: update-haxeon-wasm-hxi.sh [--check]' >&2
  exit 2
fi
"$haxeon_dir/scripts/haxeon-ffi-audit" \
  --target=wasm32-unknown-wasi --target=wasm32-unknown-emscripten \
  --profile=portable-abi32 --library=nativekit --interface=NativeKitAudio \
  --depends=NativeKit --dependency-hxi="$haxeon_dir/packages/platform/bindings/nativekit-wasm.hxi" \
  --include="$nativekit_dir/modules/audio/include" --include="$nativekit_dir/modules/audio/bindings" \
  --include="$nativekit_dir/include" --exclude-header="$nativekit_dir/include/nativekit.h" \
  --exclude-header="$nativekit_dir/include/nativekit_resource.h" \
  --source-label=modules/audio/bindings/nativekit_audio_import.h \
  --output="$destination" "$nativekit_dir/modules/audio/bindings/nativekit_audio_import.h"
if [[ ${1:-} == --check ]]; then
  diff -u "$output" "$destination"
fi
