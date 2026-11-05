#!/usr/bin/env bash
# Print the checkout-built HashLink directory; never select the bootstrap VM.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) preset=windows-msvc ;;
  *) preset=release ;;
esac
while IFS='=' read -r name path; do
  if [[ $name == "$preset" && -n $path ]]; then
    printf '%s/%s\n' "$root" "$path"
    exit 0
  fi
done < "$root/cmake/hashlink-output-paths.txt"
echo "Missing HashLink output path for $preset" >&2
exit 1
