#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
hl="$root_dir/.tools/hashlink/hl"

if [[ ! -x "$haxe" || ! -x "$hl" ]]; then
	echo "missing local toolchain; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

"$root_dir/scripts/build-native.sh" >/dev/null
mkdir -p "$root_dir/out"
"$haxe" --cwd "$root_dir" "$root_dir/benchmarks/benchmark.hxml"
LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink" "$hl" "$root_dir/out/benchmark.hl" "$@"
