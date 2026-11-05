#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-test-driver.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
cp "$root_dir/.tools/hashlink/hl" "$work/hl"
cp "$root_dir/out/haxeon_runtime.hdll" "$work/haxeon_runtime.hdll"
for library in "$root_dir/.tools/hashlink"/libhl.so* "$root_dir/.tools/hashlink"/libhl*.dylib "$root_dir/.tools/hashlink"/libhl*.dll; do
	if [[ -f "$library" ]]; then cp -L "$library" "$work/"; fi
done
build_hl=${HAXEON_BUILD_HL:-$work/haxeon-build.hl}
if [[ -z ${HAXEON_BUILD_HL:-} ]]; then
	"$root_dir/.tools/haxe/haxe" --cwd "$root_dir" -cp src -hl "$build_hl" -main build.HaxeonBuild
fi
(cd "$root_dir" && LD_LIBRARY_PATH="$work${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	DYLD_LIBRARY_PATH="$work${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$work/hl" "$build_hl" test "${1:-4}")
