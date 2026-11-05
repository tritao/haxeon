#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "$0")/.." && pwd)
hashlink_dir=$("$root_dir/scripts/hashlink-path.sh")
if [[ ! -x "$hashlink_dir/hl" ]]; then
	echo "Missing checkout-built HashLink: $hashlink_dir/hl; run scripts/build-native.sh first" >&2
	exit 1
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-test-driver.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
cp "$hashlink_dir/hl" "$work/hl"
cp "$root_dir/out/haxeon_runtime.hdll" "$work/haxeon_runtime.hdll"
for library in "$hashlink_dir"/libhl.so* "$hashlink_dir"/libhl*.dylib "$hashlink_dir"/libhl*.dll; do
	if [[ -f "$library" ]]; then cp -L "$library" "$work/"; fi
done
build_hl=${HAXEON_BUILD_HL:-$work/haxeon-build.hl}
if [[ -z ${HAXEON_BUILD_HL:-} ]]; then
	"$root_dir/.tools/haxe/haxe" --cwd "$root_dir" -cp src -hl "$build_hl" -main build.HaxeonBuild
fi
(cd "$root_dir" && LD_LIBRARY_PATH="$work${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	DYLD_LIBRARY_PATH="$work${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$work/hl" "$build_hl" test "${1:-4}")
