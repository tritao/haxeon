#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
home=${HAXEON_HOME:-$repo_dir}
haxe=${HAXEON_HAXE:-"$home/.tools/haxe/haxe"}
project_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-git-project.XXXXXX")
package_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-git-package.XXXXXX")
second_project_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-git-project-second.XXXXXX")
source_cache=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-source-cache.XXXXXX")
lock_before=$(mktemp "${TMPDIR:-/tmp}/haxeon-git-lock.XXXXXX")
trap 'rm -rf -- "$project_dir" "$second_project_dir" "$package_dir" "$source_cache" "$lock_before"' EXIT

if [[ ! -x "$haxe" ]]; then
	echo "missing Haxe executable: $haxe" >&2
	exit 1
fi

mkdir -p "$package_dir/src" "$project_dir/src"
printf '%s\n' '{"version":1,"package":{"name":"foo"},"sourceRoots":["src"]}' > "$package_dir/haxeon.json"
printf '%s\n' 'package foo;' '' 'class Foo {' '    public static function answer():Int' '        return 42;' '}' > "$package_dir/src/Foo.hx"
git -C "$package_dir" init -q
git -C "$package_dir" checkout -q -b main
git -C "$package_dir" config user.email haxeon@example.invalid
git -C "$package_dir" config user.name Haxeon
git -C "$package_dir" add haxeon.json src/Foo.hx
git -C "$package_dir" commit -q -m 'add foo package'

package_url="file://$package_dir"
printf '%s\n' '{"version":1,"package":{"name":"app"},"entry":"Main","sourceRoots":["src"],"dependencies":{}}' > "$project_dir/haxeon.json"
printf '%s\n' 'package app;' '' 'import foo.Foo;' '' 'function main():Int' '    return Foo.answer();' > "$project_dir/src/Main.hx"

run_cli() {
	HAXEON_HOME="$home" HAXEON_SOURCE_CACHE="$source_cache" HAXEON_COMPILER_SOURCE="$repo_dir/src" "$haxe" --cwd "$repo_dir" -cp "$repo_dir/src" --run tools.HaxeonCli "$@"
}

run_cli add --project "$project_dir/haxeon.json" --git "$package_url" --rev main foo
grep -q '"foo"' "$project_dir/haxeon.json"
run_cli install --project "$project_dir/haxeon.json"
test -s "$project_dir/haxeon.lock"
revision=$(git -C "$package_dir" rev-parse HEAD)
grep -q "$revision" "$project_dir/haxeon.lock"
test "$(find "$source_cache/git" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1
cp "$project_dir/haxeon.lock" "$lock_before"

mkdir -p "$second_project_dir/src"
cp "$project_dir/haxeon.json" "$second_project_dir/haxeon.json"
cp "$project_dir/src/Main.hx" "$second_project_dir/src/Main.hx"
second_install_output=$(run_cli install --project "$second_project_dir/haxeon.json")
[[ "$second_install_output" == *"Installed 2 packages"* ]]
test "$(find "$source_cache/git" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1

run_cli install --locked --project "$project_dir/haxeon.json"
cmp -s "$lock_before" "$project_dir/haxeon.lock"
tree_output=$(run_cli tree --project "$project_dir/haxeon.json")
[[ "$tree_output" == *"app [path:.]"* ]]
[[ "$tree_output" == *"foo [git:$package_url@$revision]"* ]]
why_output=$(run_cli why foo --project "$project_dir/haxeon.json")
[[ "$why_output" == "app -> foo" ]]
run_cli update --project "$project_dir/haxeon.json"
grep -q "$revision" "$project_dir/haxeon.lock"
run_cli install --locked --project "$project_dir/haxeon.json"

run_cli build --project "$project_dir/haxeon.json"
test -s "$project_dir/build/host/main.hl"

sed -i 's/"rev": "main"/"rev": "other"/' "$project_dir/haxeon.json"
set +e
locked_output=$(run_cli install --locked --project "$project_dir/haxeon.json" 2>&1)
locked_status=$?
set -e
if [[ $locked_status -eq 0 ]]; then
	echo "expected locked install to reject a changed manifest" >&2
	exit 1
fi
[[ "$locked_output" == *"disagrees with the manifest"* ]]

echo "PASS: Git dependency resolution, immutable revisions, lockfile validation, and graph inspection"
