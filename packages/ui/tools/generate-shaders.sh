#!/usr/bin/env bash
set -euo pipefail

module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(cd "$module_dir/../.." && pwd)
"$("$root/scripts/shader-tool-path.sh")" "$module_dir/shaders/shaders.json" "$@"
