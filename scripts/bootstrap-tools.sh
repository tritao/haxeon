#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
tools_dir="$root_dir/.tools"
haxe_dir="$tools_dir/haxe"
hashlink_dir="$tools_dir/hashlink"

mkdir -p "$tools_dir"

if [[ ! -x "$haxe_dir/haxe" ]]; then
    archive="$tools_dir/haxe-4.3.7-linux64.tar.gz"
    curl -fL https://github.com/HaxeFoundation/haxe/releases/download/4.3.7/haxe-4.3.7-linux64.tar.gz -o "$archive"
    unpack_dir=$(mktemp -d)
    tar -xzf "$archive" -C "$unpack_dir"
    mv "$unpack_dir"/haxe_* "$haxe_dir"
    rmdir "$unpack_dir"
fi

if [[ ! -x "$hashlink_dir/hl" ]]; then
    git clone https://github.com/HaxeFoundation/hashlink.git "$hashlink_dir"
    git -C "$hashlink_dir" checkout 864721a5fca5ac2f5f5cfdf34639274b5b34a4bc
    make -C "$hashlink_dir" -j"$(nproc)" hl
fi

"$haxe_dir/haxe" --version
"$hashlink_dir/hl" --version
