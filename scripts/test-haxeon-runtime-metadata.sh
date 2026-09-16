#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
hl="$root_dir/.tools/hashlink/hl"
output="$root_dir/out/haxeon-runtime-patch.hl"

mapfile -t sources < <(cd "$root_dir" && find src stdlib tests -type f -name '*.hx' -print | LC_ALL=C sort)
"$haxe" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--output="$output" --entry=runtime.RuntimePatchTransactionMain \
	--root=src --root=stdlib --root=tests --root=tests/runtime "${sources[@]}"

runtime_path="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
LD_LIBRARY_PATH="$runtime_path" "$hl" "$output"
