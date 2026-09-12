#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/../.." && pwd)
output="$root_dir/out/process-output-capture-test.hl"
runtime="$root_dir/.tools/hashlink/hl"
compiler=${HAXEON_COMPILER:-"$root_dir/bootstrap/compiler.hl"}

mapfile -t sources < <(find "$root_dir/src" "$root_dir/stdlib" "$root_dir/tests/compiler" -type f -name '*.hx' -print | LC_ALL=C sort)
LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink" "$runtime" "$compiler" \
	--output="$output" --entry=ProcessOutputCaptureMain --root="$root_dir/src" --root="$root_dir/stdlib" \
	--root="$root_dir/tests/compiler" --define=haxeon "${sources[@]}"
LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink" "$runtime" "$output" --runtime="$runtime" --program="$output"
