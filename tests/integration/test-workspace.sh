#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
home=${HAXEON_HOME:-$repo_dir}
haxe=${HAXEON_HAXE:-"$home/.tools/haxe/haxe"}
project_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-workspace.XXXXXX")
source_cache=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-workspace-cache.XXXXXX")
trap 'rm -rf -- "$project_dir" "$source_cache"' EXIT

if [[ ! -x "$haxe" ]]; then
	echo "missing Haxe executable: $haxe" >&2
	exit 1
fi

mkdir -p "$project_dir/src" "$project_dir/packages/foo/src"
printf '%s\n' '{"version":1,"package":{"name":"foo"},"sourceRoots":["src"]}' > "$project_dir/packages/foo/haxeon.json"
printf '%s\n' 'package foo;' '' 'class Foo {' '    public static function answer():Int' '        return 42;' '}' > "$project_dir/packages/foo/src/Foo.hx"
printf '%s\n' '{"version":1,"package":{"name":"app"},"entry":"Main","sourceRoots":["src"],"workspace":["packages/foo"],"dependencies":{"foo":{"git":"file:///does/not/exist/foo.git","rev":"main"}}}' > "$project_dir/haxeon.json"
printf '%s\n' 'package app;' '' 'import foo.Foo;' '' 'function main():Int' '    return Foo.answer();' > "$project_dir/src/Main.hx"

run_cli() {
	HAXEON_HOME="$home" HAXEON_SOURCE_CACHE="$source_cache" HAXEON_COMPILER_SOURCE="$repo_dir/src" "$haxe" --cwd "$repo_dir" -cp "$repo_dir/src" --run tools.HaxeonCli "$@"
}

run_cli install --project "$project_dir/haxeon.json"
test -s "$project_dir/haxeon.lock"
grep -q '"workspace": "packages/foo"' "$project_dir/haxeon.lock"
test ! -d "$source_cache/git"
run_cli install --locked --project "$project_dir/haxeon.json"
tree_output=$(run_cli tree --project "$project_dir/haxeon.json")
[[ "$tree_output" == *"app [path:.]"* ]]
[[ "$tree_output" == *"foo [workspace:packages/foo]"* ]]
why_output=$(run_cli why foo --project "$project_dir/haxeon.json")
[[ "$why_output" == "app -> foo" ]]
run_cli build --project "$project_dir/haxeon.json"
test -s "$project_dir/build/host/main.hl"

echo "PASS: workspace members override external sources and share package semantics"
