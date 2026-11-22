#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# The physical path: the CLI reports resolved paths, and macOS temporary directories sit behind the /var -> /private/var link.
project_dir=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/haxeon-cli.XXXXXX")" && pwd -P)
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
# What Gradle packages, as Gradle on its own asks for it: no Android SDK is needed for a project without native code.
android_inputs="$android_project/gradle inputs.properties"
"$cli" build --target android --project "$android_project" --gradle-inputs "$android_inputs"
android_module="$android_project/build/android-arm64/app.hl"
for artifact in "" .hli .entry .hcs; do
	test -s "$android_module$artifact"
done
grep -qxF "module=$android_module" "$android_inputs"
grep -qxF "entry=$android_module.entry" "$android_inputs"
"$cli" build --target android --project "$android_project" --plan | grep -F "$android_module.hcs" >/dev/null

# The bundled demo, from a copy so its build stays out of the checkout.
android_demo="$project_dir/android demo"
mkdir -p "$android_demo"
cp "$repo_dir/android/demo/haxeon.toml" "$repo_dir/android/demo/Main.hx" "$android_demo/"
"$cli" build --target android --project "$android_demo/haxeon.toml" --gradle-inputs "$android_demo/inputs.properties"
for artifact in "" .hli .entry .hcs; do
	test -s "$android_demo/build/android-arm64/app.hl$artifact"
done

# The Gradle wrapper reads its own properties, so it names its Gradle there; it must be the one android/versions.txt names.
gradle_version=$(sed -n 's/^gradle=//p' "$repo_dir/android/versions.txt")
if ! grep -qF "/gradle-$gradle_version-bin.zip" "$repo_dir/android/gradle/wrapper/gradle-wrapper.properties"; then
	echo "android/gradle/wrapper/gradle-wrapper.properties does not name Gradle $gradle_version (android/versions.txt)" >&2
	exit 1
fi

set +e
"$cli" run --project "$project_dir" -- hello
run_status=$?
set -e
if [[ $run_status -ne 42 ]]; then
	echo "expected haxeon run to return 42, got $run_status" >&2
	exit 1
fi

echo "PASS: project CLI init, doctor, target listing, host run, wasm32 build, and Android asset generation"
