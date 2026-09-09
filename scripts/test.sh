#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
hl="$root_dir/.tools/hashlink/hl"

if [[ ! -x "$haxe" || ! -x "$hl" ]]; then
	echo "missing local toolchain; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

if [[ ${SKIP_FORMAT_CHECK:-0} != 1 ]]; then
	"$root_dir/scripts/format.sh" --check
fi

"$root_dir/scripts/build-native.sh" >/dev/null
mkdir -p "$root_dir/out"

"$root_dir/tests/differential/run.sh"
"$haxe" --cwd "$root_dir" -cp src --run build.HaxeonBuild test "${TEST_JOBS:-16}"
"$root_dir/tests/integration/test-native-call.sh"
