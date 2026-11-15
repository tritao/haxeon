#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
hl="$("$root_dir/scripts/hashlink-path.sh")/hl"

source "$root_dir/scripts/lib/env.sh"
haxeon_require_haxe
haxeon_require_hashlink

"$root_dir/scripts/build-native.sh" >/dev/null
mkdir -p "$root_dir/out"
"$haxe" --cwd "$root_dir" "$root_dir/benchmarks/benchmark.hxml"
haxeon_export_library_path
"$hl" "$root_dir/out/benchmark.hl" "$@"
