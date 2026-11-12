#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/../.." && pwd)
output="$root_dir/out/process-output-capture-test.hl"
runtime="$("$root_dir/scripts/hashlink-path.sh")/hl"
# The checked-in bootstrap/compiler.hl predates the runtime's current natives (it emits haxeon_runtime@__array_index_of_any), so the compiler under
# test is this checkout's: the one the caller prebuilt, or one built here.
compiler=${HAXEON_COMPILER:-${HAXEON_COMPILER_HL:-}}
if [[ -z $compiler ]]; then
	compiler="$root_dir/out/process-output-capture-compiler.hl"
	"$root_dir/.tools/haxe/haxe" --cwd "$root_dir" common.hxml -hl "$compiler" -main compiler.tools.HaxeonCompiler
fi

sources=()
while IFS= read -r source; do
	sources+=("$source")
done < <(find "$root_dir/src" "$root_dir/stdlib" "$root_dir/tests/compiler" -type f -name '*.hx' -print | LC_ALL=C sort)
if [[ "$(uname -s)" == "Darwin" ]]; then
	export DYLD_LIBRARY_PATH="$root_dir/out:$("$root_dir/scripts/hashlink-path.sh")${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
else
	export LD_LIBRARY_PATH="$root_dir/out:$("$root_dir/scripts/hashlink-path.sh")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
"$runtime" "$compiler" \
	--output="$output" --entry=ProcessOutputCaptureMain --root="$root_dir/src" --root="$root_dir/stdlib" \
	--root="$root_dir/tests/compiler" --define=haxeon "${sources[@]}"
"$runtime" "$output" --runtime="$runtime" --program="$output"
