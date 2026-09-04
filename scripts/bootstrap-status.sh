#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"

if [[ ! -x "$haxe" ]]; then
	echo "missing local Haxe toolchain; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

"$haxe" --cwd "$root_dir" -cp src --run Main bootstrap-status "$@"
