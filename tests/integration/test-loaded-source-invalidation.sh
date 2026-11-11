#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "$0")/../.." && pwd)
haxe=${HAXEON_HAXE:-"$root_dir/.tools/haxe/haxe"}
project_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-loaded-sources.XXXXXX")
trap 'rm -rf -- "$project_dir"' EXIT
mkdir -p "$project_dir/src"
cat > "$project_dir/haxeon.json" <<'JSON'
{"version":1,"package":{"name":"app"},"entry":"Main","sources":["src/Main.hx"],"sourceRoots":["src"],"scopeSourceRoots":false}
JSON
cat > "$project_dir/src/Main.hx" <<'HX'
function main():Int return Dependency.answer();
HX
write_dependency() {
	printf 'class Dependency { public static function answer():Int return %s; }\n' "$1" > "$project_dir/src/Dependency.hx"
}
build_project() {
	HAXEON_HOME="$root_dir" HAXEON_COMPILER_SOURCE="$root_dir/src" "$haxe" --cwd "$root_dir" -cp "$root_dir/src" --run tools.HaxeonCli build --project "$project_dir/haxeon.json"
}
check_exit() {
	local status=0
	"$root_dir/scripts/hl" "$project_dir/build/host/main.hl" || status=$?
	[[ $status == "$1" ]]
}
write_dependency 41
build_project
check_exit 41
build_project > "$project_dir/clean.log"
rg -q 'clean \(fingerprint match\)' "$project_dir/clean.log"
write_dependency 42
build_project
check_exit 42
build_project > "$project_dir/clean.log"
rg -q 'clean \(fingerprint match\)' "$project_dir/clean.log"
# A changed dependency graph must publish a new report, including the newly loaded module.
printf '%s\n' 'class Dependency { public static function answer():Int return Extra.answer(); }' > "$project_dir/src/Dependency.hx"
printf '%s\n' 'class Extra { public static function answer():Int return 43; }' > "$project_dir/src/Extra.hx"
build_project
check_exit 43
printf '%s\n' 'class Extra { public static function answer():Int return 44; }' > "$project_dir/src/Extra.hx"
build_project
check_exit 44
rm "$project_dir/build/host/main.hl.inputs.json"
build_project
check_exit 44
echo 'PASS: loaded source-root dependencies invalidate cached builds'
