#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
haxe_bin="$root_dir/.tools/haxe/haxe"
source_path="${1:-$root_dir/android/demo/Main.hx}"
state_path="${2:-$root_dir/android/app/src/main/assets/app.hcs}"
bundle_path="${3:-$root_dir/android/app/src/main/assets/app.hxr}"

if [[ ! -x "$haxe_bin" ]]; then
    echo "missing local Haxe compiler: $haxe_bin" >&2
    exit 1
fi
if [[ ! -f "$state_path" ]]; then
    echo "missing Android compiler baseline: $state_path (build the APK first)" >&2
    exit 1
fi

export LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$haxe_bin" --cwd "$root_dir" -cp src --run tools.AndroidReload "$source_path" "$state_path" "$bundle_path"
