#!/usr/bin/env bash
# Print the checkout-built HashLink directory, the bin of the checkout's SDK (cmake/hashlink-output-paths.txt); never select the
# bootstrap VM. With --build-dir, print instead the CMake build directory of the preset that publishes it (out/cmake/PRESET).
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) preset=windows-msvc ;;
  *) preset=release ;;
esac
if [[ ${1:-} == --build-dir ]]; then
  printf '%s/out/cmake/%s\n' "$root" "$preset"
  exit 0
fi
while IFS='=' read -r name path; do
  if [[ $name == "$preset" && -n $path ]]; then
    printf '%s/%s\n' "$root" "$path"
    exit 0
  fi
done < "$root/cmake/hashlink-output-paths.txt"
echo "Missing HashLink output path for $preset" >&2
exit 1
