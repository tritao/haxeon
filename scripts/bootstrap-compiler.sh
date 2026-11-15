#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
command=bootstrap

if [[ $# -gt 1 || ${1:-} != "" && ${1:-} != "--self" ]]; then
	echo "usage: $0 [--self]" >&2
	exit 2
fi
if [[ ${1:-} == "--self" ]]; then
	command=bootstrap-self
fi
source "$root_dir/scripts/lib/env.sh"
haxeon_require_haxe

"$haxe" --cwd "$root_dir" common.hxml --run build.HaxeonBuild "$command"
