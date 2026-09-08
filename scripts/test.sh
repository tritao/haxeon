#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
hl="$root_dir/vendor/hashlink/hl"

if [[ ! -x "$haxe" || ! -x "$hl" ]]; then
	echo "missing local toolchain; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

if [[ ${SKIP_FORMAT_CHECK:-0} != 1 ]]; then
	"$root_dir/scripts/format.sh" --check
fi

make -C "$root_dir/vendor/hashlink" -j2 libhl.so hl >/dev/null
mkdir -p "$root_dir/out"
cc -shared -fPIC -DHL_NAME\(n\)=realtime_##n \
	-I "$root_dir/vendor/hashlink/src" \
	"$root_dir/native/runtime.c" \
	-L "$root_dir/vendor/hashlink" -lhl \
	-Wl,-rpath,"$root_dir/vendor/hashlink" \
	-o "$root_dir/out/realtime_runtime.hdll"

"$root_dir/tests/differential/run.sh"
"$haxe" --cwd "$root_dir" -cp tests --run driver.TestDriver --root "$root_dir" --jobs "${TEST_JOBS:-16}"
