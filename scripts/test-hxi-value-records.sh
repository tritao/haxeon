#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe_bin="$root_dir/.tools/haxe/haxe"
if [[ ! -x "$haxe_bin" ]]; then
	echo "missing local Haxe compiler: $haxe_bin" >&2
	exit 1
fi

"$haxe_bin" --cwd "$root_dir" -cp src -cp tests/compiler --run HxiAbiMain
"$haxe_bin" --cwd "$root_dir" -cp src -cp tests/compiler --run HxiParserMain

probe="$root_dir/tests/native/hxi_value_records_abi.c"
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only "$probe"
clang --target=x86_64-pc-windows-msvc -std=c11 -ffreestanding -fsyntax-only "$probe"
clang --target=aarch64-linux-android21 -std=c11 -ffreestanding -fsyntax-only "$probe"

clang --target=wasm32-unknown-unknown -std=c11 -ffreestanding -fsyntax-only "$probe"
echo "PASS: HXI fixed-layout value records cover Linux, Windows, Android, and Wasm ABIs"
