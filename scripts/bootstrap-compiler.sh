#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
hl="$root_dir/.tools/hashlink/hl"
runtime="$root_dir/out/realtime_runtime.hdll"
checked_compiler="$root_dir/bootstrap/compiler.hl"
seed_compiler="$root_dir/out/bootstrap/compiler-seed.hl"
stage_one="$root_dir/out/bootstrap/compiler-stage-one.hl"
stage_two="$root_dir/out/bootstrap/compiler-stage-two.hl"
stage_three="$root_dir/out/bootstrap/compiler-stage-three.hl"
self_compiler="$root_dir/out/bootstrap/compiler-self.hl"

mode=${1:-bootstrap}
if [[ $# -gt 1 || "$mode" != "bootstrap" && "$mode" != "--self" ]]; then
	echo "usage: $0 [--self]" >&2
	exit 2
fi

if [[ ! -x "$hl" ]]; then
	echo "missing pinned HashLink executable; initialize and build vendor/hashlink" >&2
	exit 1
fi
if [[ "$mode" == "bootstrap" && ! -x "$haxe" ]]; then
	echo "missing reference Haxe compiler; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi
if [[ "$mode" == "--self" && ! -f "$checked_compiler" ]]; then
	echo "missing bootstrap/compiler.hl" >&2
	exit 1
fi

mkdir -p "$root_dir/bootstrap" "$root_dir/out/bootstrap"
"$root_dir/scripts/build-native.sh" >/dev/null

mapfile -t sources < <(cd "$root_dir" && find src stdlib -type f -name '*.hx' -print | LC_ALL=C sort)

if [[ "$mode" == "--self" ]]; then
	(
		cd "$root_dir"
		LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink" "$hl" "$checked_compiler" \
			--output=out/bootstrap/compiler-self.hl --entry=compiler.tools.HaxeonCompiler --root=src --root=stdlib "${sources[@]}"
	)
	cmp "$checked_compiler" "$self_compiler"
	cmp "$checked_compiler.functions" "$self_compiler.functions"
	echo "PASS: checked-in compiler rebuilt itself identically"
	exit 0
fi

"$haxe" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--output=out/bootstrap/compiler-seed.hl --entry=compiler.tools.HaxeonCompiler --root=src --root=stdlib "${sources[@]}"

compile_with() {
	local compiler=$1
	local output=$2
	(
		cd "$root_dir"
		LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink" "$hl" "$compiler" \
			--output="$output" --entry=compiler.tools.HaxeonCompiler --root=src --root=stdlib "${sources[@]}"
	)
}

compile_with "$seed_compiler" out/bootstrap/compiler-stage-one.hl
compile_with "$stage_one" out/bootstrap/compiler-stage-two.hl
compile_with "$stage_two" out/bootstrap/compiler-stage-three.hl
cmp "$stage_two" "$stage_three"
cmp "$stage_two.functions" "$stage_three.functions"
cp "$stage_three" "$checked_compiler"
cp "$stage_three.functions" "$checked_compiler.functions"
echo "PASS: bootstrap stages converged on an identical self-hosted compiler"
