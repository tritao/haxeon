#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
project_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-cli.XXXXXX")
trap 'rm -rf -- "$project_dir"' EXIT

cli="$repo_dir/scripts/haxeon"
(
	cd "$project_dir"
	"$cli" init
)
cat > "$project_dir/src/Main.hx" <<'HX'
function main():Int return Sys.args().length == 1 ? 42 : 43;
HX

(
	cd "$project_dir"
	"$cli" doctor
	"$cli" platforms
	"$cli" build
	test -f build/host/main.hl
	"$cli" build --target wasm32
	test -f build/wasm32/main.wasm
	wasm_header=$(od -An -tx1 -N4 build/wasm32/main.wasm | tr -d ' \n')
	test "$wasm_header" = "0061736d"
)

android_project="$project_dir/android project"
mkdir -p "$android_project"
(
	cd "$android_project"
	"$cli" init --target android
)
"$repo_dir/.tools/haxe/haxe" --cwd "$repo_dir" -cp "$repo_dir/src" --run tools.AndroidBuild \
	--project "$android_project/haxeon.json" "$android_project/build/app.hl"
for artifact in app.hl app.hli app.entry app.hcs; do
	test -s "$android_project/build/$artifact"
done

android_demo="$project_dir/android demo"
"$repo_dir/.tools/haxe/haxe" --cwd "$repo_dir" -cp "$repo_dir/src" --run tools.AndroidBuild \
	"$repo_dir/android/demo/Main.hx" "$android_demo/app.hl"
for artifact in app.hl app.hli app.entry app.hcs; do
	test -s "$android_demo/$artifact"
done

set +e
"$cli" run --project "$project_dir/haxeon.json" -- hello
run_status=$?
set -e
if [[ $run_status -ne 42 ]]; then
	echo "expected haxeon run to return 42, got $run_status" >&2
	exit 1
fi

echo "PASS: project CLI init, doctor, target listing, host run, wasm32 build, and Android asset generation"
