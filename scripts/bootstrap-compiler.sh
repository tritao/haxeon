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
if [[ ! -x "$haxe" ]]; then
	echo "missing pinned Haxe; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

"$haxe" --cwd "$root_dir" -cp src --run build.HaxeonBuild "$command"
