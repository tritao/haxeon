#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"

source "$root_dir/scripts/lib/env.sh"
haxeon_require_haxe

"$haxe" --cwd "$root_dir" common.hxml --run compiler.tools.BootstrapStatus "$@"
