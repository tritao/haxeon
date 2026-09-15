#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/../.." && pwd)
output="$root_dir/out/process-output-capture-test.hl"
runtime="$root_dir/.tools/hashlink/hl"
compiler=${HAXEON_COMPILER:-"$root_dir/bootstrap/compiler.hl"}

sources=()
while IFS= read -r source; do
	sources+=("$source")
done < <(find "$root_dir/src" "$root_dir/stdlib" "$root_dir/tests/compiler" -type f -name '*.hx' -print | LC_ALL=C sort)
if [[ "$(uname -s)" == "Darwin" ]]; then
	export DYLD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
else
	export LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
"$runtime" "$compiler" \
	--output="$output" --entry=ProcessOutputCaptureMain --root="$root_dir/src" --root="$root_dir/stdlib" \
	--root="$root_dir/tests/compiler" --define=haxeon "${sources[@]}"
"$runtime" "$output" --runtime="$runtime" --program="$output"
