#!/usr/bin/env bash
# Print the checkout-built HashLink directory, the bin of the checkout's SDK (out/sdk/bin); never the bootstrap VM. With
# --build-dir, print instead the CMake build directory of the preset that publishes it (out/cmake/PRESET); with --lib-dir, the
# SDK's static libraries for this machine (out/sdk/lib/TARGET: libhl, the profiler hooks), which C test programs link.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ ${1:-} == --lib-dir ]]; then
  libraries=("$root"/out/sdk/lib/*/)
  if [[ ${#libraries[@]} != 1 || ! -d ${libraries[0]} ]]; then
    echo "Expected one target in $root/out/sdk/lib; build the native runtime (scripts/build-native.sh)" >&2
    exit 1
  fi
  printf '%s\n' "${libraries[0]%/}"
elif [[ ${1:-} == --build-dir ]]; then
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) printf '%s/out/cmake/windows-msvc\n' "$root" ;;
    *) printf '%s/out/cmake/release\n' "$root" ;;
  esac
else
  printf '%s/out/sdk/bin\n' "$root"
fi
