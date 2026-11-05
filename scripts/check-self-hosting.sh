#!/usr/bin/env bash
# Checks that the compiler in this tree can build itself, to a fixed point, in about a minute and a half.
#
# The seed is built by running the compiler sources under the pinned Haxe interpreter; stage 1 is built by the seed and
# stage 2 by stage 1. Stages 1 and 2 must be identical. Unlike `bootstrap-compiler.sh --self` this does not use the
# checked-in compiler, so it also catches a change that the sources can no longer be built with.
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
hashlink_dir=$("$root_dir/scripts/hashlink-path.sh")
hl="$hashlink_dir/hl"
work="$root_dir/out/self-hosting"

if [[ ! -x "$haxe" ]]; then
	echo "missing local toolchain; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi
if [[ ! -x "$hl" || ! -e "$root_dir/out/haxeon_runtime.hdll" ]]; then
	echo "missing checkout-built HashLink or runtime; run scripts/build-native.sh first" >&2
	exit 1
fi

library_path="$root_dir/out:$hashlink_dir"
case "$(uname -s)" in
Darwin) export DYLD_LIBRARY_PATH="$library_path${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" ;;
*) export LD_LIBRARY_PATH="$library_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
esac

mkdir -p "$work"
sources="$work/compiler-sources.txt"
(cd "$root_dir" && find src stdlib -name '*.hx' | LC_ALL=C sort) >"$sources"

arguments=(--entry=compiler.tools.HaxeonCompiler --root=src --root=stdlib "--sources-file=$sources")

echo "seed: building the compiler with the Haxe interpreter"
"$haxe" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler "--output=$work/seed.hl" "${arguments[@]}" >"$work/seed.log" 2>&1 || {
	tail -n 20 "$work/seed.log" >&2
	echo "FAIL: the compiler sources do not build under the Haxe interpreter" >&2
	exit 1
}

previous="$work/seed.hl"
for stage in 1 2; do
	echo "stage $stage: building the compiler with $(basename "$previous")"
	(cd "$root_dir" && "$hl" "$previous" "--output=$work/stage-$stage.hl" "${arguments[@]}") >"$work/stage-$stage.log" 2>&1 || {
		tail -n 20 "$work/stage-$stage.log" >&2
		echo "FAIL: $(basename "$previous") could not build the compiler sources" >&2
		exit 1
	}
	previous="$work/stage-$stage.hl"
done

for suffix in "" ".functions"; do
	if ! cmp -s "$work/stage-1.hl$suffix" "$work/stage-2.hl$suffix"; then
		echo "FAIL: stage 1 and stage 2 differ ($work/stage-1.hl$suffix, $work/stage-2.hl$suffix)" >&2
		exit 1
	fi
done
echo "PASS: the compiler builds itself to a fixed point"
