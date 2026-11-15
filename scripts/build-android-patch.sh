#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
haxe_bin="$root_dir/.tools/haxe/haxe"
source_path="${1:-$root_dir/android/demo/Main.hx}"
state_path="${2:-$root_dir/android/app/src/main/assets/app.hcs}"
patch_path="${3:-$root_dir/android/app/src/main/assets/app.hlp}"

source "$root_dir/scripts/lib/env.sh"
haxeon_require_haxe
if [[ ! -f "$state_path" ]]; then
    echo "missing Android compiler baseline: $state_path (build the APK first)" >&2
    exit 1
fi

haxeon_export_library_path
"$haxe_bin" --cwd "$root_dir" common.hxml --run tools.AndroidPatch "$source_path" "$state_path" "$patch_path"
