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
# The program cases compile with the compiler entry point prebuilt to HashLink bytecode (HAXEON_MAIN_HL): that is the compiler as it
# ships, and a compile takes ~0.4 s where `haxe --run Main` interprets the whole compiler for ~2 s. Both tools come from the content-
# hashed cache (`haxeon dev tool-path`) unless HAXEON_BUILD_HL / HAXEON_MAIN_HL pin specific builds. HAXEON_TEST_INTERPRETED=1 runs
# the interpreter path instead, for debugging the compiler's sources under `haxe --run`.
build_hl=${HAXEON_BUILD_HL:-$("$root_dir/scripts/haxeon" dev tool-path build.HaxeonBuild)}
if [[ ${HAXEON_TEST_INTERPRETED:-} == 1 ]]; then
	unset HAXEON_MAIN_HL
elif [[ -z ${HAXEON_MAIN_HL:-} ]]; then
	export HAXEON_MAIN_HL
	HAXEON_MAIN_HL=$("$root_dir/scripts/haxeon" dev tool-path Main)
fi
# The driver rebuilds out/ and the HashLink directory, so it loads the copies in $work and neither directory may stay on its search path:
# macOS shows no loaded mappings, so the driver refuses any search path that names a directory it builds into.
without_build_directories() {
	local entry kept="" IFS=:
	for entry in $1; do
		case "$entry" in
		"" | "$root_dir/out" | "$root_dir/out/" | "$hashlink_dir" | "$hashlink_dir/") ;;
		*) kept="$kept${kept:+:}$entry" ;;
		esac
	done
	printf '%s' "$kept"
}
library_path=$(without_build_directories "${LD_LIBRARY_PATH:-}")
dyld_library_path=$(without_build_directories "${DYLD_LIBRARY_PATH:-}")
(cd "$root_dir" && LD_LIBRARY_PATH="$work${library_path:+:$library_path}" \
	DYLD_LIBRARY_PATH="$work${dyld_library_path:+:$dyld_library_path}" "$work/hl" "$build_hl" test "${1:-4}")
