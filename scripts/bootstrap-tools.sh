#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
tools_dir="$root_dir/.tools"
haxe_dir="$tools_dir/haxe"
hashlink_dir="$tools_dir/hashlink"
hashlink_source="$root_dir/vendor/hashlink"
formatter_dir="$tools_dir/formatter"
formatter_version="1.18.0"
formatter_sha256="2d29c9b56e54b2643e07ee64003c3fc30a5bc133bdcb4cc15c48f09acda7a047"
haxe_sha256="a156b3d039daa572f1f9329870ee753e3c39b7514fe8c818069323579659acca"

mkdir -p "$tools_dir"

if [[ ! -x "$haxe_dir/haxe" ]]; then
    archive="$tools_dir/haxe-4.3.7-linux64.tar.gz"
    curl -fL https://github.com/HaxeFoundation/haxe/releases/download/4.3.7/haxe-4.3.7-linux64.tar.gz -o "$archive"
	echo "$haxe_sha256  $archive" | sha256sum --check
    unpack_dir=$(mktemp -d)
    tar -xzf "$archive" -C "$unpack_dir"
    mv "$unpack_dir"/haxe_* "$haxe_dir"
    rmdir "$unpack_dir"
fi

hashlink_commit=$(git -C "$hashlink_source" rev-parse HEAD)
hashlink_stamp="$hashlink_dir/.tritao-source-commit"
if [[ ! -x "$hashlink_dir/hl" || ! -f "$hashlink_stamp" || "$(<"$hashlink_stamp")" != "$hashlink_commit" ]]; then
    make -C "$hashlink_source" -j"$(nproc)" hl
    mkdir -p "$hashlink_dir"
    cp "$hashlink_source/hl" "$hashlink_dir/hl"
    cp "$hashlink_source/libhl.so" "$hashlink_dir/libhl.so"
    printf '%s\n' "$hashlink_commit" > "$hashlink_stamp"
fi

if [[ ! -f "$formatter_dir/run.js" ]]; then
    formatter_archive="$tools_dir/formatter-$formatter_version.zip"
    curl -fL "https://lib.haxe.org/p/formatter/$formatter_version/download/" -o "$formatter_archive"
    echo "$formatter_sha256  $formatter_archive" | sha256sum --check
    mkdir -p "$formatter_dir"
    unzip -q "$formatter_archive" -d "$formatter_dir"
fi

"$haxe_dir/haxe" --version
"$hashlink_dir/hl" --version
node "$formatter_dir/run.js" --help | head -n 1
