#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
haxe=${HAXEON_HAXE:-"$repo_dir/.tools/haxe/haxe"}
hl=${HAXEON_HL:-"$("$repo_dir/scripts/hashlink-path.sh")/hl"}
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-build-executor.XXXXXX")
trap 'rm -rf -- "$temporary_dir"' EXIT

if [[ ! -x "$haxe" || ! -x "$hl" ]]; then
	echo "missing Haxe/HashLink toolchain under $repo_dir" >&2
	exit 1
fi

"$haxe" --cwd "$repo_dir" -cp "$repo_dir/src" -cp "$repo_dir/lib/haxeon-io" -cp "$repo_dir/tests/tooling" -hl "$temporary_dir/build-system.hl" -main BuildSystemMain
LD_LIBRARY_PATH="$repo_dir/out:$("$repo_dir/scripts/hashlink-path.sh")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$hl" "$temporary_dir/build-system.hl"
