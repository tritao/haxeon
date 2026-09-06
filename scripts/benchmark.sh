#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
hl="$root_dir/vendor/hashlink/hl"

if [[ ! -x "$haxe" || ! -x "$hl" ]]; then
	echo "missing local toolchain; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

make -C "$root_dir/vendor/hashlink" -j2 libhl.so hl >/dev/null
mkdir -p "$root_dir/out"
cc -shared -fPIC -DHL_NAME\(n\)=realtime_##n \
	-I "$root_dir/vendor/hashlink/src" \
	"$root_dir/native/runtime.c" \
	-L "$root_dir/vendor/hashlink" -lhl \
	-Wl,-rpath,"$root_dir/vendor/hashlink" \
	-o "$root_dir/out/realtime_runtime.hdll"
"$haxe" --cwd "$root_dir" "$root_dir/benchmark.hxml"
LD_LIBRARY_PATH="$root_dir/out:$root_dir/vendor/hashlink" "$hl" "$root_dir/out/benchmark.hl" "$@"
