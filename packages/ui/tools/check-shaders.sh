#!/usr/bin/env bash
set -euo pipefail

module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exec "$module_dir/tools/generate-shaders.sh" --check "$@"
