#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# The physical path: the CLI reports resolved paths, and macOS temporary directories sit behind the /var -> /private/var link.
project_dir=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/haxeon-cli-XXXXXX")" && pwd -P)
trap 'rm -rf -- "$project_dir"' EXIT

cli="$repo_dir/scripts/haxeon"
(
	cd "$project_dir"
	"$cli" create . --template console
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

android_project="$project_dir/with spaces/android-project"
mkdir -p "$android_project"
(
	cd "$android_project"
	"$cli" create . --platforms android
)
# Preparing the generated assets needs no Android toolchain.
generated="$android_project/build/generated/android"
"$cli" build --target android --project "$android_project" --gradle-inputs "$generated/inputs.properties"
for artifact in app.hl app.hli app.hcs; do
	test -s "$generated/assets/$artifact"
done
grep -qF "id=com.example.android_project" "$generated/inputs.properties"
grep -qF "HAXEON_APP_ID" "$generated/haxeon.cmake"
"$cli" build --target android --project "$android_project" --plan | grep -F "app.hl.hcs" >/dev/null

gradle_version=$(sed -n 's/^gradle=//p' "$repo_dir/native/android/versions.txt")
grep -qF "/gradle-$gradle_version-bin.zip" "$android_project/android/gradle/wrapper/gradle-wrapper.properties"

set +e
"$cli" run --project "$project_dir" -- hello
run_status=$?
set -e
if [[ $run_status -ne 42 ]]; then
	echo "expected haxeon run to return 42, got $run_status" >&2
	exit 1
fi

echo "PASS: project CLI create, doctor, target listing, host run, wasm32 build, and Android asset generation"
