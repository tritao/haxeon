#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
haxe_bin="$root_dir/.tools/haxe/haxe"
output_file="$root_dir/android/app/src/main/assets/app.hl"

if [[ ! -x "$haxe_bin" ]]; then
    echo "missing local Haxe compiler: $haxe_bin" >&2
    exit 1
fi

mkdir -p "$(dirname "$output_file")"
rm -f "$root_dir/android/app/src/main/assets/app.hlp" "$root_dir/android/app/src/main/assets/app.hxr" "$root_dir/android/app/src/main/assets/app.hcs.pending"

export LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$haxe_bin" --cwd "$root_dir" -cp src --run tools.AndroidBuild "$root_dir/android/demo/Main.hx" "$output_file"
