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
# The program cases compile with the compiler entry point prebuilt to HashLink bytecode (HAXEON_MAIN_HL), as scripts/test.sh does: that
# is the compiler as it ships, and a compile takes ~0.4 s where `haxe --run Main` interprets the whole compiler for ~2 s. scripts/test.sh
# builds it once and exports it; run alone, this script builds it here. HAXEON_TEST_INTERPRETED=1 runs the interpreter path instead,
# for debugging the compiler's sources under `haxe --run`.
builds=()
if [[ -z ${HAXEON_BUILD_HL:-} ]]; then
	"$root_dir/.tools/haxe/haxe" --cwd "$root_dir" common.hxml -hl "$build_hl" -main build.HaxeonBuild &
	builds+=($!)
fi
if [[ ${HAXEON_TEST_INTERPRETED:-} == 1 ]]; then
	unset HAXEON_MAIN_HL
elif [[ -z ${HAXEON_MAIN_HL:-} ]]; then
	export HAXEON_MAIN_HL="$work/haxeon-main.hl"
	"$root_dir/.tools/haxe/haxe" --cwd "$root_dir" common.hxml -hl "$HAXEON_MAIN_HL" -main Main &
	builds+=($!)
fi
for build in "${builds[@]+"${builds[@]}"}"; do wait "$build"; done
(cd "$root_dir" && LD_LIBRARY_PATH="$work${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	DYLD_LIBRARY_PATH="$work${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$work/hl" "$build_hl" test "${1:-4}")
