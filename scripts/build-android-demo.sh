#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
haxe_bin="$root_dir/.tools/haxe/haxe"
output_file="$root_dir/android/app/src/main/assets/app.hl"

source "$root_dir/scripts/lib/env.sh"
haxeon_require_haxe

mkdir -p "$(dirname "$output_file")"
rm -f "$root_dir/android/app/src/main/assets/app.hlp" "$root_dir/android/app/src/main/assets/app.hxr" "$root_dir/android/app/src/main/assets/app.hcs.pending"

haxeon_export_library_path
"$haxe_bin" --cwd "$root_dir" common.hxml --run tools.AndroidBuild "$root_dir/android/demo/Main.hx" "$output_file"
