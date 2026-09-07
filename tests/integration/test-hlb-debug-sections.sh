#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$repo_dir/out"
make -C "$repo_dir/vendor/hashlink" -j2 libhl.so hl >/dev/null
"$repo_dir/.tools/haxe/haxe" --cwd "$repo_dir" -cp src -cp tests --run DebugSectionFixture \
	"$repo_dir/out/debug-sections-valid.hl" "$repo_dir/out/debug-sections-malformed.hl"
LD_LIBRARY_PATH="$repo_dir/vendor/hashlink" "$repo_dir/vendor/hashlink/hl" "$repo_dir/out/debug-sections-valid.hl"
if LD_LIBRARY_PATH="$repo_dir/vendor/hashlink" "$repo_dir/vendor/hashlink/hl" "$repo_dir/out/debug-sections-malformed.hl" \
	>"$repo_dir/out/debug-sections-malformed.stdout" 2>"$repo_dir/out/debug-sections-malformed.stderr"; then
	echo "HashLink accepted a truncated debug section" >&2
	exit 1
fi
echo "PASS: HLB v7 loads known metadata, skips unknown sections, and rejects truncated sections"
