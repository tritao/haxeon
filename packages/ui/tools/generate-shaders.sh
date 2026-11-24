#!/usr/bin/env bash
set -euo pipefail

module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(cd "$module_dir/../.." && pwd)
python3 "$root/vendor/nativekit/modules/gpu/tools/shaders.py" "$module_dir/shaders/shaders.json" "$@"
