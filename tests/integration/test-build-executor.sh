#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
home=${HAXEON_HOME:-$repo_dir}
haxe=${HAXEON_HAXE:-"$home/.tools/haxe/haxe"}
hl=${HAXEON_HL:-"$home/.tools/hashlink/hl"}
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-build-executor.XXXXXX")
trap 'rm -rf -- "$temporary_dir"' EXIT

if [[ ! -x "$haxe" || ! -x "$hl" ]]; then
	echo "missing Haxe/HashLink toolchain under $home" >&2
	exit 1
fi

"$haxe" --cwd "$repo_dir" -cp "$repo_dir/src" -cp "$repo_dir/tests/tooling" -hl "$temporary_dir/build-system.hl" -main BuildSystemMain
LD_LIBRARY_PATH="$home/out:$home/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$hl" "$temporary_dir/build-system.hl"
