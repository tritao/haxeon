#!/usr/bin/env bash
# Checks that the compiler in this tree can build itself, to a fixed point, in about a minute and a half.
#
# The seed is built by running the compiler sources under the pinned Haxe interpreter; stage 1 is built by the seed and
# stage 2 by stage 1. Stages 1 and 2 must be identical. Unlike `bootstrap-compiler.sh --self` this does not use the
# checked-in compiler, so it also catches a change that the sources can no longer be built with.
#
# Afterwards it compares stage 2 with the checked-in `bootstrap/compiler.hl` and says when that file is stale. With
# `--update` it copies stage 2 over it; commit the result with the compiler change it belongs to.
set -euo pipefail

update=0
case "${1:-}" in
"") ;;
--update) update=1 ;;
*)
	echo "usage: $0 [--update]" >&2
	exit 2
	;;
esac

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
hl="$root_dir/.tools/hashlink/hl"
work="$root_dir/out/self-hosting"

if [[ ! -x "$haxe" || ! -x "$hl" ]]; then
	echo "missing local toolchain; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi
if [[ ! -e "$root_dir/out/haxeon_runtime.hdll" ]]; then
	"$root_dir/scripts/build-native.sh" >/dev/null
fi

library_path="$root_dir/out:$root_dir/.tools/hashlink"
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

checked="$root_dir/bootstrap/compiler.hl"
if cmp -s "$work/stage-2.hl" "$checked" && cmp -s "$work/stage-2.hl.functions" "$checked.functions"; then
	echo "bootstrap/compiler.hl is up to date"
elif [[ $update == 1 ]]; then
	cp "$work/stage-2.hl" "$checked"
	cp "$work/stage-2.hl.functions" "$checked.functions"
	echo "UPDATED: bootstrap/compiler.hl now matches stage 2; commit it"
else
	echo "STALE: bootstrap/compiler.hl differs from stage 2; run $0 --update and commit it"
fi
