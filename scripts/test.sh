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
bash "$root_dir/scripts/test-hxi-value-records.sh"
bash "$root_dir/scripts/test-messagepack-interop.sh"

"$root_dir/tests/differential/run.sh"
"$haxe" --cwd "$root_dir" -cp src --run build.HaxeonBuild test "${TEST_JOBS:-16}"
"$root_dir/tests/integration/test-haxeon-formatter.sh"
"$root_dir/tests/integration/test-native-call.sh"
"$root_dir/tests/integration/test-hxi-call.sh"
"$root_dir/tests/integration/test-cxx-hxi-call.sh"
"$root_dir/tests/integration/test-cxx-project-ffi.sh"
"$root_dir/tests/integration/test-cxx-project-ffi-thunks.sh"
"$root_dir/tests/integration/test-cxx-project-ffi-cmake.sh"
"$root_dir/tests/integration/test-cxx-owned.sh"
"$root_dir/tests/integration/test-cxx-lifetime.sh"
"$root_dir/tests/integration/test-cxx-virtual.sh"
"$root_dir/tests/integration/test-cxx-thunks.sh"
"$root_dir/tests/integration/test-cxx-string-view.sh"
"$root_dir/tests/integration/test-cxx-span.sh"
"$root_dir/tests/integration/test-cxx-msvc-profile.sh"
"$root_dir/tests/integration/test-cmake-native-package.sh"
"$root_dir/tests/integration/test-git-package-lock.sh"
"$root_dir/tests/integration/test-workspace.sh"
"$root_dir/tests/integration/test-profiler-disconnect.sh"
bash "$root_dir/tests/integration/test-process-output-capture.sh"
